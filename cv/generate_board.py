#!/usr/bin/env python3
"""Generate a test shooting board image with ArUco corner markers and a red laser dot."""

import cv2
import numpy as np
import argparse

# Board layout constants — must match detect.py
BOARD_SIZE = 800
MARKER_SIZE = 80
MARGIN = 20
NUM_RINGS = 10
BOARD_INNER_MARGIN = MARKER_SIZE + MARGIN * 2   # 120px clearance for markers
MAX_RADIUS = (BOARD_SIZE - 2 * BOARD_INNER_MARGIN) // 2  # 280px
RING_WIDTH = MAX_RADIUS / NUM_RINGS             # 28px per ring


def generate_board(dot_x=None, dot_y=None, no_dot=False, perspective=False, output="test_board.png", seed=42):
    if seed is not None:
        np.random.seed(seed)

    img = np.ones((BOARD_SIZE, BOARD_SIZE, 3), dtype=np.uint8) * 255
    center = (BOARD_SIZE // 2, BOARD_SIZE // 2)

    # Draw rings outermost → innermost so smaller circles paint over larger ones
    ring_colors = [(180, 180, 180), (220, 220, 220)]
    for i in range(NUM_RINGS, 0, -1):
        radius = int(RING_WIDTH * i)
        cv2.circle(img, center, radius, ring_colors[i % 2], -1)
        cv2.circle(img, center, radius, (0, 0, 0), 1)

    # Ring score labels (outermost = 1, innermost = 10)
    for i in range(1, NUM_RINGS + 1):
        radius = int(RING_WIDTH * i)
        score_label = str(NUM_RINGS + 1 - i)
        cv2.putText(img, score_label,
                    (center[0] + radius - 14, center[1] - 3),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.35, (0, 0, 0), 1)

    # Crosshair
    cv2.line(img, (center[0], center[1] - 12), (center[0], center[1] + 12), (0, 0, 0), 1)
    cv2.line(img, (center[0] - 12, center[1]), (center[0] + 12, center[1]), (0, 0, 0), 1)

    # ArUco markers at corners: ID 0=TL, 1=TR, 2=BL, 3=BR
    try:
        aruco_dict = cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_4X4_50)
    except AttributeError:
        aruco_dict = cv2.aruco.Dictionary_get(cv2.aruco.DICT_4X4_50)

    corner_origins = [
        (MARGIN, MARGIN),
        (BOARD_SIZE - MARGIN - MARKER_SIZE, MARGIN),
        (MARGIN, BOARD_SIZE - MARGIN - MARKER_SIZE),
        (BOARD_SIZE - MARGIN - MARKER_SIZE, BOARD_SIZE - MARGIN - MARKER_SIZE),
    ]
    for marker_id, (x, y) in enumerate(corner_origins):
        try:
            marker_img = cv2.aruco.generateImageMarker(aruco_dict, marker_id, MARKER_SIZE)
        except AttributeError:
            marker_img = cv2.aruco.drawMarker(aruco_dict, marker_id, MARKER_SIZE)
        img[y:y + MARKER_SIZE, x:x + MARKER_SIZE] = cv2.cvtColor(marker_img, cv2.COLOR_GRAY2BGR)

    if not no_dot:
        # Red dot — default to random position within the ring area
        rng_range = int(MAX_RADIUS * 0.85)
        if dot_x is None:
            dot_x = BOARD_SIZE // 2 + np.random.randint(-rng_range, rng_range)
        if dot_y is None:
            dot_y = BOARD_SIZE // 2 + np.random.randint(-rng_range, rng_range)

        # Simulate laser: outer glow + bright core
        cv2.circle(img, (dot_x, dot_y), 7, (0, 0, 180), -1)
        cv2.circle(img, (dot_x, dot_y), 4, (0, 0, 255), -1)
        cv2.circle(img, (dot_x, dot_y), 2, (120, 120, 255), -1)

    if perspective:
        jitter = BOARD_SIZE // 8
        src = np.float32([[0, 0], [BOARD_SIZE, 0], [0, BOARD_SIZE], [BOARD_SIZE, BOARD_SIZE]])
        dst = np.float32([
            [np.random.randint(0, jitter),              np.random.randint(0, jitter)],
            [BOARD_SIZE - np.random.randint(0, jitter), np.random.randint(0, jitter)],
            [np.random.randint(0, jitter),              BOARD_SIZE - np.random.randint(0, jitter)],
            [BOARD_SIZE - np.random.randint(0, jitter), BOARD_SIZE - np.random.randint(0, jitter)],
        ])
        M = cv2.getPerspectiveTransform(src, dst)
        img = cv2.warpPerspective(img, M, (BOARD_SIZE, BOARD_SIZE))

    cv2.imwrite(output, img)
    print(f"Saved: {output}")
    if not no_dot and dot_x is not None:
        dist = np.sqrt((dot_x - BOARD_SIZE / 2) ** 2 + (dot_y - BOARD_SIZE / 2) ** 2)
        expected_score = max(1, NUM_RINGS - int(dist / RING_WIDTH)) if dist <= MAX_RADIUS else 0
        print(f"Dot position: ({dot_x}, {dot_y})")
        print(f"Expected score: {expected_score}  (dist={dist:.1f}px)")
    return dot_x, dot_y


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate test shooting board")
    parser.add_argument("--dot-x", type=int, default=None, help="Red dot X (default: random)")
    parser.add_argument("--dot-y", type=int, default=None, help="Red dot Y (default: random)")
    parser.add_argument("--no-dot", action="store_true", help="Generate board without red dot (for printing)")
    parser.add_argument("--perspective", action="store_true", help="Apply random perspective warp")
    parser.add_argument("--output", default="test_board.png")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()
    generate_board(args.dot_x, args.dot_y, args.no_dot, args.perspective, args.output, args.seed)
