#!/usr/bin/env python3
"""
Detect shooting board via ArUco corners, correct perspective via homography,
detect red laser dot, and calculate score.
"""

import cv2
import numpy as np
import argparse
import sys

# Must match generate_board.py
BOARD_SIZE = 800
MARKER_SIZE = 80
MARGIN = 20
NUM_RINGS = 10
BOARD_INNER_MARGIN = MARKER_SIZE + MARGIN * 2
MAX_RADIUS = (BOARD_SIZE - 2 * BOARD_INNER_MARGIN) // 2  # 280px
RING_WIDTH = MAX_RADIUS / NUM_RINGS                       # 28px

# Canonical center of each ArUco marker in the flat board space
CANONICAL_CENTERS = {
    0: (MARGIN + MARKER_SIZE // 2,              MARGIN + MARKER_SIZE // 2),
    1: (BOARD_SIZE - MARGIN - MARKER_SIZE // 2, MARGIN + MARKER_SIZE // 2),
    2: (MARGIN + MARKER_SIZE // 2,              BOARD_SIZE - MARGIN - MARKER_SIZE // 2),
    3: (BOARD_SIZE - MARGIN - MARKER_SIZE // 2, BOARD_SIZE - MARGIN - MARKER_SIZE // 2),
}


# ---------------------------------------------------------------------------
# Step 1 — Board detection
# ---------------------------------------------------------------------------

def detect_aruco(img):
    """Detect 4 corner ArUco markers. Returns {id: (cx, cy)} or None."""
    try:
        aruco_dict = cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_4X4_50)
        params = cv2.aruco.DetectorParameters()
        detector = cv2.aruco.ArucoDetector(aruco_dict, params)
        corners, ids, _ = detector.detectMarkers(img)
    except AttributeError:
        # OpenCV < 4.7 fallback
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


def compute_homography(detected_centers):
    """Map detected marker centers → canonical positions."""
    ids = sorted(detected_centers.keys())
    src = np.float32([detected_centers[i] for i in ids])
    dst = np.float32([CANONICAL_CENTERS[i] for i in ids])
    H, _ = cv2.findHomography(src, dst)
    return H


# ---------------------------------------------------------------------------
# Step 2 — Laser dot detection
# ---------------------------------------------------------------------------

def detect_red_dot(warped_img):
    """
    Find the red laser dot in the homography-corrected board image.
    Returns ((cx, cy), debug_mask) or (None, mask).
    """
    hsv = cv2.cvtColor(warped_img, cv2.COLOR_BGR2HSV)

    # Red wraps around the HSV hue wheel (0-10 and 170-180)
    mask_lo = cv2.inRange(hsv, np.array([0,   120, 120]), np.array([10,  255, 255]))
    mask_hi = cv2.inRange(hsv, np.array([170, 120, 120]), np.array([180, 255, 255]))
    mask = cv2.bitwise_or(mask_lo, mask_hi)

    # Remove noise, fill small gaps
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)

    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None, mask

    # Prefer blobs in the plausible laser-dot size range; fall back to largest
    valid = [c for c in contours if 15 < cv2.contourArea(c) < 3000]
    best = max(valid or contours, key=cv2.contourArea)

    M = cv2.moments(best)
    if M["m00"] == 0:
        return None, mask

    cx = M["m10"] / M["m00"]
    cy = M["m01"] / M["m00"]
    return (cx, cy), mask


# ---------------------------------------------------------------------------
# Step 3 — Scoring
# ---------------------------------------------------------------------------

def calculate_score(dot_x, dot_y):
    """
    Distance from canonical board center → ring score 1-10, or 0 (miss).
    Also returns raw pixel distance for display.
    """
    cx, cy = BOARD_SIZE / 2.0, BOARD_SIZE / 2.0
    dist = np.sqrt((dot_x - cx) ** 2 + (dot_y - cy) ** 2)

    if dist > MAX_RADIUS:
        return 0, dist

    ring = int(dist / RING_WIDTH)          # 0 = bullseye band
    score = NUM_RINGS - ring
    return max(1, min(10, score)), dist


def normalize_coords(dot_x, dot_y):
    """Canonical pixel → 0-1 normalized (0.5, 0.5 = board center)."""
    return dot_x / BOARD_SIZE, dot_y / BOARD_SIZE


# ---------------------------------------------------------------------------
# Annotation helpers
# ---------------------------------------------------------------------------

def annotate_original(img, detected_centers):
    out = img.copy()
    for mid, (cx, cy) in detected_centers.items():
        cv2.circle(out, (int(cx), int(cy)), 8, (0, 255, 0), 2)
        cv2.putText(out, f"ID{mid}", (int(cx) + 10, int(cy) - 5),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)
    return out


def annotate_warped(warped, dot, score, dist):
    out = warped.copy()
    if dot:
        dx, dy = int(dot[0]), int(dot[1])
        cv2.circle(out, (dx, dy), 12, (0, 255, 0), 2)
        cv2.circle(out, (dx, dy), 2,  (0, 255, 0), -1)
        label = f"Score: {score}  dist: {dist:.1f}px"
        cv2.putText(out, label, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 200, 0), 2)
    return out


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------

def detect(image_path, output_prefix="result"):
    img = cv2.imread(image_path)
    if img is None:
        print(f"ERROR: cannot read '{image_path}'")
        sys.exit(1)

    # --- Step 1: board detection ---
    print("[1] Detecting ArUco markers...")
    detected = detect_aruco(img)
    if detected is None:
        print("ERROR: need all 4 ArUco markers (IDs 0-3), found fewer.")
        sys.exit(1)
    print(f"    Detected IDs: {sorted(detected.keys())}")
    for mid, pos in sorted(detected.items()):
        print(f"    ID{mid}: ({pos[0]:.1f}, {pos[1]:.1f})")

    # --- Step 2: homography + warp ---
    print("[2] Computing homography and warping...")
    H = compute_homography(detected)
    warped = cv2.warpPerspective(img, H, (BOARD_SIZE, BOARD_SIZE))

    # --- Step 3: dot detection ---
    print("[3] Detecting red dot...")
    dot, mask = detect_red_dot(warped)
    if dot is None:
        print("ERROR: red dot not found — check HSV thresholds or image quality.")
        sys.exit(1)
    print(f"    Dot centroid: ({dot[0]:.1f}, {dot[1]:.1f})")

    # --- Step 4: score ---
    score, dist = calculate_score(dot[0], dot[1])
    norm_x, norm_y = normalize_coords(dot[0], dot[1])

    print()
    print("=== RESULT ===")
    print(f"  Score:      {score}/10  {'(MISS)' if score == 0 else ''}")
    print(f"  Distance:   {dist:.1f} px from center")
    print(f"  Normalized: ({norm_x:.4f}, {norm_y:.4f})")

    # --- Save annotated outputs ---
    cv2.imwrite(f"{output_prefix}_original.png", annotate_original(img, detected))
    cv2.imwrite(f"{output_prefix}_warped.png",   annotate_warped(warped, dot, score, dist))
    cv2.imwrite(f"{output_prefix}_mask.png",     mask)
    print(f"\nSaved: {output_prefix}_original.png / _warped.png / _mask.png")

    return {
        "score": score,
        "distance_px": round(dist, 2),
        "dot_canonical": (round(dot[0], 2), round(dot[1], 2)),
        "dot_normalized": (round(norm_x, 4), round(norm_y, 4)),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Detect board + laser dot, calculate score")
    parser.add_argument("image", help="Input image path")
    parser.add_argument("--output", default="result", help="Output filename prefix")
    args = parser.parse_args()
    detect(args.image, args.output)
