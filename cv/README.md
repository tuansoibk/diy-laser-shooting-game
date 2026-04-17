## generate_board.py


python3 generate_board.py                        # random dot

python3 generate_board.py --dot-x 400 --dot-y 400  # bullseye

python3 generate_board.py --perspective            # simulate camera angle

## detect.py — the pipeline:

ArUco marker detection → 4 corner positions

Homography computation → perspective-corrected warp

HSV red masking + blob detection → dot centroid

Ring distance math → score 1-10

python3 detect.py test_board.png

`outputs: result_original.png, result_warped.png, result_mask.png`

Key design notes:

opencv-contrib-python is required (not plain opencv-python) — aruco is in the contrib module

Scoring constants (RING_WIDTH, MAX_RADIUS, etc.) are shared between both files — keep them in sync when tuning

The result_mask.png output is your main debugging tool for tuning red detection on real images

Next step: once you have a real photo, run detect.py against it and the mask will immediately show you what's being picked up as "red". HSV thresholds will likely need tuning.