"""
CV pipeline: receive JPEG bytes → detect board (ArUco + homography) →
detect red dot → calculate score. Returns a result dict or None.
"""

import cv2
import numpy as np

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


# ---------------------------------------------------------------------------
# Dot detection
# ---------------------------------------------------------------------------

def _detect_red_dots(warped_img):
    """Returns list of (cx, cy) for every valid red blob in canonical space."""
    hsv = cv2.cvtColor(warped_img, cv2.COLOR_BGR2HSV)
    mask_lo = cv2.inRange(hsv, np.array([0,   120, 120]), np.array([10,  255, 255]))
    mask_hi = cv2.inRange(hsv, np.array([170, 120, 120]), np.array([180, 255, 255]))
    mask = cv2.bitwise_or(mask_lo, mask_hi)

    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)

    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    valid = [c for c in contours if 15 < cv2.contourArea(c) < 3000]

    dots = []
    for c in valid:
        M = cv2.moments(c)
        if M["m00"] > 0:
            dots.append((M["m10"] / M["m00"], M["m01"] / M["m00"]))
    return dots


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
# Public API
# ---------------------------------------------------------------------------

def process_frame(jpeg_bytes: bytes):
    """
    Full pipeline: JPEG bytes → board detection → dot detection → score.

    Returns:
        {x, y, score, distance_px}  — x/y are normalised 0-1 (0.5 = centre)
        None                        — board or dot not detected
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

    dots = _detect_red_dots(warped)
    if not dots:
        return None

    if len(dots) > 1:
        return {"multiple_dots": True}

    dot = dots[0]
    score, dist = _score(dot[0], dot[1])

    return {
        "multiple_dots": False,
        "x":           round(dot[0] / BOARD_SIZE, 4),
        "y":           round(dot[1] / BOARD_SIZE, 4),
        "score":       score,
        "distance_px": round(dist, 2),
    }
