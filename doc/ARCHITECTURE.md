# Architecture

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                          Same Wi-Fi LAN                         │
│                                                                 │
│  ┌──────────────┐   JPEG + hint   ┌────────────────────────┐   │
│  │  iPhone App  │ ─────────────── │   FastAPI Backend      │   │
│  │  (Swift)     │ ◄── score ───── │   (Python / OpenCV)    │   │
│  └──────────────┘                 └────────────┬───────────┘   │
│                                                │               │
│  ┌──────────────┐   poll /current  ┌───────────▼───────────┐   │
│  │  Web Browser │ ──────────────── │   SQLite Database     │   │
│  │  (HTML/JS)   │ ◄── scores ───── │   (game.db)           │   │
│  └──────────────┘                  └───────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Components

### iOS App (`ios/`)

Responsibilities: camera access, real-time dot detection, frame submission.

**Key files**

| File | Role |
|------|------|
| `ContentView.swift` | Root SwiftUI view, `AppViewModel`, all view states |
| `CameraManager.swift` | `AVCaptureSession` setup (ultra-wide, 4:3 format), exposure lock/unlock |
| `RedDotDetector.swift` | Per-frame red pixel clustering on raw `CVPixelBuffer` |
| `BoardDetector.swift` | Vision-based rectangle detection to locate the board quad |
| `APIClient.swift` | Multipart POST to `/detect` and `/debug/detect` |

**App state machine**

```
connect ──► idle ──► armed ──► posting ──► result
                ▲                              │
                └──────────────────────────────┘
```

**Red dot detection** (`RedDotDetector`)

Scans every frame at stride-2 (every other pixel) in BGRA space. A pixel is "red" when:
- `R ≥ 160` (minimum brightness — rejects dark noise)
- `R / max(G, B) ≥ 1.5` (ratio-based — naturally adapts to scene brightness)

Nearby qualifying pixels are merged into clusters. Clusters with 20–50,000 pixels are reported as dot candidates. Ratio-based thresholding (vs. absolute dominance) means the detector stays accurate across different exposure levels without false-positives on warm-toned surfaces.

**Board detection** (`BoardDetector`)

Uses `VNDetectRectanglesRequest` to find the target board quad in the frame. When a board quad is found, only dots whose normalised position falls inside the quad are forwarded to the backend, eliminating false triggers from objects in the room.

**Exposure management**

The user locks exposure before shooting to prevent auto-exposure from washing out the laser dot against a bright background. `lockExposure()` snapshots current ISO (clamped to `activeFormat` limits) and duration into custom mode. `unlockExposure()` restores continuous auto-exposure so the camera can re-adjust when the target is moved.

---

### Backend (`backend/`)

Responsibilities: board warp, dot detection, scoring, persistence, API.

**Key files**

| File | Role |
|------|------|
| `main.py` | FastAPI routes, request/response handling |
| `cv_pipeline.py` | Full CV pipeline: ArUco → homography → HSV → scoring |
| `database.py` | SQLite connection context manager, schema |
| `models.py` | Pydantic request/response models |

**CV pipeline** (`cv_pipeline.process_frame`)

```
JPEG bytes
    │
    ▼
Decode image  (OpenCV)
    │
    ▼
Detect ArUco markers  (DICT_4X4_50, 4 corner IDs 0-3)
    │  fail → return None
    ▼
Compute homography  (4-point, src corners → 800×800 canonical space)
    │
    ▼
Warp perspective  → flat 800×800 board image
    │
    ▼
─── Detection cascade (stops at first success) ───────────────────
│
├─ 1. Strict HSV mask  (sat≥140, val≥140)
│      + 21×21 morphological CLOSE  (fills overexposed glare hole)
│      + 5×5 OPEN  (removes speckle)
│      + Contour filter: area 15–3000 px², convex-hull circularity ≥ 0.45
│
├─ 2. Guided relaxed HSV  (sat≥100, val≥100, within 100 px of iOS hint)
│      + Circularity ≥ 0.30
│
└─ 3. Bright-spot fallback  (within 100 px of iOS hint)
       Finds peak luminance cluster using 5×5 blurred grayscale.
       Requires peak > 180 AND peak − regional_mean > 20.
       Used when dot is so overexposed the red glow fails HSV.
    │
    ▼
Board boundary filter  (must be within MAX_RADIUS + RING_WIDTH of centre)
    │
    ▼
Hint disambiguation  (multiple dots → pick closest to iOS hint)
    │
    ▼
Score  (ring = floor(distance / RING_WIDTH), score = 10 − ring, min 1)
```

**Board coordinate system**

```
(0,0) ┌──────────────────────┐ (800,0)
      │  [0]            [1]  │   ArUco marker centres (canonical):
      │   ●              ●   │   0: ( 60,  60)
      │                      │   1: (740,  60)
      │        (+)           │   2: ( 60, 740)
      │      centre          │   3: (740, 740)
      │   ●              ●   │
      │  [2]            [3]  │   Board centre: (400, 400)
(0,800)└──────────────────────┘ (800,800)  MAX_RADIUS = 280 px
```

**Scoring rings**

| Distance from centre | Score |
|---------------------|-------|
| 0 – 28 px | 10 |
| 28 – 56 px | 9 |
| … | … |
| 252 – 280 px | 1 |
| > 280 px | 0 |

**Database schema**

```
game
 ├── id, player_name, created_at
 └── rounds (1:N)
      ├── id, game_id, round_number, started_at, ended_at
      └── shots (1:N)
           └── id, round_id, score, x, y, distance_px, created_at
```

`x` and `y` are stored as normalised 0–1 values (canonical_px / 800).

**Debug artefacts**

Every miss saves a side-by-side JPEG to `backend/debug/`:

| Filename prefix | Contents |
|----------------|----------|
| `no_dot_*` | Warped board with contour labels + HSV mask. Reason tag: `strict_miss`, `hint_miss`, `guided_miss` |
| `mismatch_*` | Backend dot (green) vs iOS hint (red) when positions disagree |
| `debug_raw_*` | Raw incoming JPEG from `/debug/detect` endpoint |

---

### Web Frontend (`frontend/`)

Single-page app that polls `/current` every second. Displays the live score list for the active round and provides game/round controls in the header.

**Key state**

| Variable | Description |
|----------|-------------|
| `state.gameId` / `state.roundId` | Active game and round |
| `state.maxShots` | Shots-per-round limit (localStorage, default 10) |
| `state.paused` | Pause polling toggle |

**Round lifecycle**

1. User clicks **New Game** → `POST /games`
2. User clicks **New Round** → `POST /games/{id}/rounds`
3. App polls `/current` → fetches `/rounds/{id}` each tick
4. When `shots.length >= maxShots` → auto-calls `PATCH /rounds/{id}/end` and shows splash
5. User clicks **Continue** on splash → back to step 2

---

### Board Generation (`cv/`)

`generate_board.py` produces `board_print.png`: an 800×800 pt canvas with 10 concentric scoring rings and four ArUco markers (DICT_4X4_50, IDs 0–3) at the corners. Print at A3 or larger for reliable marker detection at shooting distance.

## Data Flow: Single Shot

```
1. iPhone camera frame (4:3, ~1280×960, BGRA)
        │
        ▼
2. RedDotDetector scans → finds red cluster → normalised (hintX, hintY)
        │
        ▼
3. BoardDetector finds quad → confirms dot is inside board
        │
        ▼
4. Encode JPEG (quality 0.85) → POST /detect with hint_x, hint_y
        │
        ▼
5. Backend: ArUco → homography → warp → HSV detection cascade
        │
        ▼
6. Score computed → INSERT INTO shot → return DetectResponse
        │
        ▼
7. iOS shows score overlay for 1 s → re-arms automatically
        │
        ▼
8. Web frontend next poll tick → fetches updated shots → updates scoreboard
```
