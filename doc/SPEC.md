# Laser Shooting Game — Project Specification

## Overview

A DIY laser-pointer shooting game for personal use. A physical target board is mounted at a distance; the shooter fires a laser (pointer, bore-sight, or airsoft laser) at it. An iPhone mounted on a tripod monitors the board and automatically detects the laser dot the moment it appears. Detected shots are scored in real time and displayed on a web dashboard that shows a live visual overlay of all shots in the current round.

---

## System Components

### 1. iPhone Camera App

The primary sensor of the system. It runs a continuous computer vision loop against the live camera feed and automatically triggers when a laser dot is detected — no manual button press required.

**Responsibilities**
- Lock camera exposure and white balance after calibration (prevents auto-exposure from washing out the laser dot)
- Run a lightweight per-frame red-blob trigger on-device to detect laser dot presence
- On trigger: capture the frame and POST it as a JPEG to the backend
- Display the last result (score, shot position) returned by the backend
- Provide a "Calibrate" button to re-run board detection when the setup changes

**Tech stack:** Swift / SwiftUI, AVFoundation (camera + exposure lock), CoreImage (on-device HSV trigger)

---

### 2. Backend API

Handles all heavy computer vision, game state, and data persistence.

**Responsibilities**
- Receive JPEG frames from the iPhone app and run full CV pipeline (see CV Approach below)
- Manage game and round lifecycle (start, end, score history)
- Store all shot data with position and score
- Serve game data to the web frontend

**Tech stack:** Python, FastAPI, OpenCV (opencv-contrib), SQLite (via SQLModel or raw sqlite3)

---

### 3. Frontend Web App

A real-time display board shown on a laptop or TV near the shooting range.

**Responsibilities**
- Display current game state: player, round number, total score
- Render a visual overlay of the target with all shot positions for the current round plotted as dots
- Color-code shots by score value (e.g. green = 8-10, yellow = 5-7, red = 1-4)
- Poll the backend every 1–2 seconds (or use WebSocket) for new shots

**Tech stack:** React (or plain HTML + Canvas), communicates with backend via REST

---

## CV Approach

The CV pipeline runs entirely on the backend in Python using OpenCV. The iPhone performs only a lightweight trigger check.

### Board Detection

The physical target board has **ArUco markers** (small QR-like fiducial squares from the `cv2.aruco` module) affixed at its four corners with IDs 0, 1, 2, 3 assigned to top-left, top-right, bottom-left, bottom-right respectively.

```
[ArUco #0] ─────────── [ArUco #1]
     │                       │
     │    ○ 1              │
     │   ○ 5 ○             │
     │  ○ 10  ○            │
     │   ○ 5 ○             │
     │    ○ 1              │
     │                       │
[ArUco #2] ─────────── [ArUco #3]
```

**Why ArUco:**
- Each marker has a unique ID so the system always knows which corner is which regardless of orientation or camera angle
- Robust to partial occlusion and perspective distortion
- Detection is a single OpenCV call

**Homography correction:**
Once the 4 marker centers are detected in the distorted camera frame, a homography matrix is computed that maps those detected positions to their known canonical positions in a flat 800×800 coordinate space. `cv2.warpPerspective` produces a corrected top-down view of the board regardless of camera angle.

This means:
- The setup can be repositioned freely between sessions
- A single "Calibrate" action re-establishes the board geometry
- All subsequent shot coordinates are in a stable, device-independent coordinate system

**Ring scoring geometry** is hardcoded as a function of the canonical board size — no visual ring detection needed. Score is calculated from the Euclidean distance of the dot from the board center.

### Laser Dot Detection

Detection is split across two stages:

**Stage 1 — On-device trigger (iPhone, CoreImage)**
A simple HSV color filter checks each camera frame for any high-saturation, high-brightness red pixel cluster. This is intentionally permissive (may false-positive). It runs at full frame rate (~30fps) and costs ~2ms/frame. When a cluster is found, the frame is captured and sent to the backend.

**Stage 2 — Precise detection (backend, OpenCV)**
After homography correction, the warped board image is processed:

1. Convert to HSV
2. Mask for red in both hue ranges (0–10° and 170–180°, to handle the HSV hue wrap-around)
3. Apply morphological close + open to remove noise and fill gaps
4. Find contours; filter by area (15–3000 px²) and pick the largest valid blob
5. Compute blob centroid via image moments → this is the shot position

The backend acts as a gate: if no valid dot is found after full CV processing, the shot is rejected and nothing is recorded. This eliminates the false positives from stage 1.

**Important physical constraint:** the target board background should be **black rings on white** — red laser dots stand out maximally against white. Avoid red in the ring design.

---

## Data Model

```
Game
  id          INTEGER PK
  player_name TEXT
  created_at  DATETIME

Round
  id          INTEGER PK
  game_id     INTEGER FK → Game
  round_number INTEGER
  started_at  DATETIME
  ended_at    DATETIME (nullable)

Shot
  id          INTEGER PK
  round_id    INTEGER FK → Round
  score       INTEGER (0–10, 0 = miss)
  x           REAL    (normalized 0–1, 0.5 = center)
  y           REAL    (normalized 0–1, 0.5 = center)
  distance_px REAL    (pixels from board center in canonical space)
  created_at  DATETIME
```

---

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| POST | `/games` | Start a new game |
| GET | `/games/:id` | Get game with all rounds and shots |
| POST | `/games/:id/rounds` | Start a new round |
| PATCH | `/rounds/:id/end` | End the current round |
| POST | `/rounds/:id/detect` | Submit a JPEG frame; returns shot result or rejection |
| GET | `/rounds/:id/shots` | Get all shots for a round |

---

## Coordinate System

All shot positions are stored in **normalized 0–1 coordinates** derived from the 800×800 canonical board space:

- `(0.5, 0.5)` = board center (bullseye)
- `(0.0, 0.0)` = top-left corner
- `(1.0, 1.0)` = bottom-right corner

This makes coordinates device-independent and directly usable by the web frontend to render dots on any canvas size.

---

## Scoring

Standard 10-ring scoring in the canonical 800×800 space:

| Distance from center | Score |
|----------------------|-------|
| 0 – 28 px | 10 |
| 28 – 56 px | 9 |
| 56 – 84 px | 8 |
| … | … |
| 252 – 280 px | 1 |
| > 280 px | 0 (miss) |

Ring width = 28px. Max ring radius = 280px. Both derived from board layout constants.

---

## Deployment

This is a personal-use system running on a local network. No cloud hosting required.

- Backend runs on a laptop on the same WiFi network as the iPhone
- Frontend opens in a browser on the same laptop or any device on the network
- iPhone connects to the backend via local IP (configured once at setup)
