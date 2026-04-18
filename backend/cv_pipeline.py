"""
CV pipeline: receive JPEG bytes → detect board (ArUco + homography) →
detect red dot → calculate score. Returns a result dict or None.
"""

import cv2
import numpy as np
import os
from datetime import datetime

# Board layout constants — must match cv/generate_board.py
BOARD_SIZE   = 800
MARKER_SIZE  = 80
MARGIN       = 20
NUM_RINGS    = 10
BOARD_INNER_MARGIN = MARKER_SIZE + MARGIN * 2   # 120px
MAX_RADIUS   = (BOARD_SIZE - 2 * BOARD_INNER_MARGIN) // 2  # 280px
RING_WIDTH   = MAX_RADIUS / NUM_RINGS                       # 28px

# Canonical ArUco marker centers in flat board space (ID → (x, y))
CANONICAL_CENTERS = {
    0: (MARGIN + MARKER_SIZE // 2,              MARGIN + MARKER_SIZE // 2),
    1: (BOARD_SIZE - MARGIN - MARKER_SIZE // 2, MARGIN + MARKER_SIZE // 2),
    2: (MARGIN + MARKER_SIZE // 2,              BOARD_SIZE - MARGIN - MARKER_SIZE // 2),
    3: (BOARD_SIZE - MARGIN - MARKER_SIZE // 2, BOARD_SIZE - MARGIN - MARKER_SIZE // 2),
}


# ---------------------------------------------------------------------------
# Board detection
# ---------------------------------------------------------------------------

def _detect_aruco(img):
    """Returns {id: (cx, cy)} for all 4 corner markers, or None."""
    try:
        aruco_dict = cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_4X4_50)
        params = cv2.aruco.DetectorParameters()
        detector = cv2.aruco.ArucoDetector(aruco_dict, params)
        corners, ids, _ = detector.detectMarkers(img)
    except AttributeError:
        aruco_dict = cv2.aruco.Dictionary_get(cv2.aruco.DICT_4X4_50)
        params = cv2.aruco.DetectorParameters_create()
        corners, ids, _ = cv2.aruco.detectMarkers(img, aruco_dict, parameters=params)

    if ids is None or len(ids) < 4:
        return None

    detected = {}
    for marker_corners, marker_id in zip(corners, ids.flatten()):
        mid = int(marker_id)
        if mid in CANONICAL_CENTERS:
            cx, cy = marker_corners[0].mean(axis=0)
            detected[mid] = (float(cx), float(cy))

    return detected if len(detected) == 4 else None


def _compute_homography(detected_centers):
    ids = sorted(detected_centers.keys())
    src = np.float32([detected_centers[i] for i in ids])
    dst = np.float32([CANONICAL_CENTERS[i]  for i in ids])
    H, _ = cv2.findHomography(src, dst)
    return H


# Distance threshold (canonical px) below which backend+iOS positions agree
HINT_MATCH_THRESHOLD = 80
# Radius (canonical px) for guided search around the hint position
GUIDED_SEARCH_RADIUS = 100
DEBUG_DIR = os.path.join(os.path.dirname(__file__), "debug")


# ---------------------------------------------------------------------------
# Dot detection
# ---------------------------------------------------------------------------

def _hsv_mask(warped_img, sat_min=140, val_min=140):
    hsv = cv2.cvtColor(warped_img, cv2.COLOR_BGR2HSV)
    mask_lo = cv2.inRange(hsv, np.array([0,   sat_min, val_min]), np.array([10,  255, 255]))
    mask_hi = cv2.inRange(hsv, np.array([170, sat_min, val_min]), np.array([180, 255, 255]))
    mask = cv2.bitwise_or(mask_lo, mask_hi)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
    return mask


def _contours_to_dots(contours, min_circularity=0.45):
    dots = []
    for c in contours:
        area = cv2.contourArea(c)
        if not (15 < area < 3000):
            continue
        perimeter = cv2.arcLength(c, True)
        if perimeter == 0:
            continue
        if (4 * np.pi * area / (perimeter ** 2)) < min_circularity:
            continue
        M = cv2.moments(c)
        if M["m00"] > 0:
            dots.append((M["m10"] / M["m00"], M["m01"] / M["m00"]))
    return dots


def _detect_red_dots(warped_img):
    """Strict detection — returns list of (cx, cy) in canonical space."""
    mask = _hsv_mask(warped_img, sat_min=140, val_min=140)
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    return _contours_to_dots(contours, min_circularity=0.45)


def _detect_red_dots_guided(warped_img, hint_cx, hint_cy):
    """
    Relaxed detection restricted to a circle around the hint position.
    Used when strict detection finds nothing but iOS reported a dot.
    """
    # Relaxed HSV mask
    mask = _hsv_mask(warped_img, sat_min=100, val_min=100)

    # Restrict to hint region
    region = np.zeros(mask.shape, dtype=np.uint8)
    cv2.circle(region, (int(hint_cx), int(hint_cy)), GUIDED_SEARCH_RADIUS, 255, -1)
    mask = cv2.bitwise_and(mask, region)

    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    return _contours_to_dots(contours, min_circularity=0.30)


def _hint_to_canonical(img, H, hint_x, hint_y):
    """Transform a normalised frame position through H to canonical board coords."""
    h, w = img.shape[:2]
    pt = np.array([[[hint_x * w, hint_y * h]]], dtype=np.float32)
    transformed = cv2.perspectiveTransform(pt, H)
    return float(transformed[0][0][0]), float(transformed[0][0][1])


def _dot_distance(a, b):
    return float(np.sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2))


def _save_mismatch(jpeg_bytes, warped, backend_dot, hint_canonical):
    """Save annotated debug image when backend and iOS positions disagree."""
    os.makedirs(DEBUG_DIR, exist_ok=True)
    vis = warped.copy()
    # Backend dot → green circle
    cv2.circle(vis, (int(backend_dot[0]), int(backend_dot[1])), 10, (0, 255, 0), 2)
    cv2.putText(vis, "backend", (int(backend_dot[0]) + 12, int(backend_dot[1])),
                cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)
    # iOS hint → red circle
    cv2.circle(vis, (int(hint_canonical[0]), int(hint_canonical[1])), 10, (0, 80, 255), 2)
    cv2.putText(vis, "ios_hint", (int(hint_canonical[0]) + 12, int(hint_canonical[1])),
                cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 80, 255), 1)

    ts = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    path = os.path.join(DEBUG_DIR, f"mismatch_{ts}.jpg")
    cv2.imwrite(path, vis)
    print(f"[cv_pipeline] mismatch saved → {path}")


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------

def _score(dot_x, dot_y):
    dist = np.sqrt((dot_x - BOARD_SIZE / 2) ** 2 + (dot_y - BOARD_SIZE / 2) ** 2)
    if dist > MAX_RADIUS:
        return 0, dist
    ring = int(dist / RING_WIDTH)
    return max(1, min(10, NUM_RINGS - ring)), dist


# ---------------------------------------------------------------------------
# Debug helper
# ---------------------------------------------------------------------------

def debug_frame(jpeg_bytes: bytes):
    """
    Same pipeline as process_frame but returns a full diagnostic dict:
      stage          — where the pipeline stopped ("decode","aruco","dots","ok")
      aruco_ids      — list of detected ArUco IDs (or [])
      contours       — list of dicts per contour with area/circularity/hsv/passed
      result         — same as process_frame, or None
      debug_image    — base64 JPEG: warped board with contours annotated
                       (or the original image if warp failed)
    """
    import base64

    out = {"stage": "decode", "aruco_ids": [], "contours": [], "result": None, "debug_image": None}

    buf = np.frombuffer(jpeg_bytes, dtype=np.uint8)
    img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    if img is None:
        return out

    detected = _detect_aruco(img)
    out["aruco_ids"] = sorted(detected.keys()) if detected else []

    if detected is None:
        out["stage"] = "aruco"
        # Annotate original image with "ArUco failed" label
        vis = img.copy()
        cv2.putText(vis, "ArUco not detected", (20, 40),
                    cv2.FONT_HERSHEY_SIMPLEX, 1.0, (0, 0, 255), 2)
        out["debug_image"] = _encode_b64(vis)
        return out

    H = _compute_homography(detected)
    warped = cv2.warpPerspective(img, H, (BOARD_SIZE, BOARD_SIZE))
    vis = warped.copy()

    # Draw board centre and ring circles for reference
    cx, cy = BOARD_SIZE // 2, BOARD_SIZE // 2
    for ring in range(1, NUM_RINGS + 1):
        r = int(ring * RING_WIDTH)
        cv2.circle(vis, (cx, cy), r, (60, 60, 60), 1)

    hsv = cv2.cvtColor(warped, cv2.COLOR_BGR2HSV)
    mask_lo = cv2.inRange(hsv, np.array([0,   140, 140]), np.array([10,  255, 255]))
    mask_hi = cv2.inRange(hsv, np.array([170, 140, 140]), np.array([180, 255, 255]))
    mask = cv2.bitwise_or(mask_lo, mask_hi)
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)

    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    contour_info = []
    for c in contours:
        area = cv2.contourArea(c)
        perimeter = cv2.arcLength(c, True)
        circularity = (4 * np.pi * area / (perimeter ** 2)) if perimeter > 0 else 0.0
        M = cv2.moments(c)
        pcx = int(M["m10"] / M["m00"]) if M["m00"] > 0 else 0
        pcy = int(M["m01"] / M["m00"]) if M["m00"] > 0 else 0

        # Sample mean HSV at the contour centre
        roi = hsv[max(0, pcy-3):pcy+4, max(0, pcx-3):pcx+4]
        hsv_mean = roi.mean(axis=(0, 1)).tolist() if roi.size > 0 else [0, 0, 0]

        fail = None
        if not (15 < area < 3000):
            fail = f"area={area:.0f}"
        elif circularity < 0.45:
            fail = f"circ={circularity:.2f}"

        passed = fail is None
        color  = (0, 220, 0) if passed else (0, 80, 220)
        cv2.drawContours(vis, [c], -1, color, 2)
        label  = f"{'OK' if passed else fail} a={area:.0f} c={circularity:.2f}"
        cv2.putText(vis, label, (pcx + 8, pcy),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.4, color, 1)

        contour_info.append({
            "cx": pcx, "cy": pcy,
            "area": round(area, 1),
            "circularity": round(circularity, 3),
            "hsv_mean": [round(v, 1) for v in hsv_mean],
            "passed": passed,
            "fail_reason": fail,
        })

    out["contours"] = contour_info
    out["stage"] = "dots" if not any(c["passed"] for c in contour_info) else "ok"
    out["result"] = process_frame(jpeg_bytes)

    # Composite: warped | mask (converted to BGR)
    mask_bgr = cv2.cvtColor(mask, cv2.COLOR_GRAY2BGR)
    composite = np.hstack([vis, mask_bgr])
    out["debug_image"] = _encode_b64(composite)
    return out


def _encode_b64(img):
    import base64
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 85])
    return base64.b64encode(buf.tobytes()).decode() if ok else None


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def process_frame(jpeg_bytes, hint_x=None, hint_y=None):
    """
    Full pipeline: JPEG bytes → board detection → dot detection → score.

    hint_x / hint_y — normalised 0-1 position reported by the iOS detector
    (raw frame coords). Used to guide detection and validate the result.

    Returns:
        {x, y, score, distance_px, guided}  — guided=True when hint was needed
        {"multiple_dots": True}             — more than one dot found
        None                                — board or dot not detected
    """
    buf = np.frombuffer(jpeg_bytes, dtype=np.uint8)
    img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    if img is None:
        return None

    detected = _detect_aruco(img)
    if detected is None:
        return None

    H = _compute_homography(detected)
    warped = cv2.warpPerspective(img, H, (BOARD_SIZE, BOARD_SIZE))

    # Transform iOS hint to canonical board coordinates
    hint_canonical = None
    if hint_x is not None and hint_y is not None:
        try:
            hint_canonical = _hint_to_canonical(img, H, hint_x, hint_y)
        except Exception:
            hint_canonical = None

    # --- Strict detection ---
    dots = _detect_red_dots(warped)
    guided = False

    # --- Guided fallback: strict detection missed but iOS saw a dot ---
    if not dots and hint_canonical is not None:
        dots = _detect_red_dots_guided(warped, *hint_canonical)
        if dots:
            guided = True

    # Keep only dots inside (or just outside) the board target
    board_cx, board_cy = BOARD_SIZE / 2.0, BOARD_SIZE / 2.0
    dots = [d for d in dots
            if np.sqrt((d[0] - board_cx) ** 2 + (d[1] - board_cy) ** 2) <= MAX_RADIUS + RING_WIDTH]

    if not dots:
        return None

    # --- Hint-based disambiguation: multiple dots → pick closest to hint ---
    if len(dots) > 1 and hint_canonical is not None:
        closest = min(dots, key=lambda d: _dot_distance(d, hint_canonical))
        if _dot_distance(closest, hint_canonical) <= HINT_MATCH_THRESHOLD:
            dots = [closest]

    if len(dots) > 1:
        return {"multiple_dots": True}

    dot = dots[0]

    # --- Mismatch check: backend and iOS disagree on position ---
    if hint_canonical is not None and not guided:
        if _dot_distance(dot, hint_canonical) > HINT_MATCH_THRESHOLD:
            _save_mismatch(jpeg_bytes, warped, dot, hint_canonical)

    score, dist = _score(dot[0], dot[1])

    return {
        "multiple_dots": False,
        "guided":        guided,
        "x":             round(dot[0] / BOARD_SIZE, 4),
        "y":             round(dot[1] / BOARD_SIZE, 4),
        "score":         score,
        "distance_px":   round(dist, 2),
    }
