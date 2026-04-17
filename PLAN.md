# Laser Shooting Game — Implementation Plan

## Guiding Principles

- Build and validate each layer before adding the next
- CV detection is the highest-risk component — validate it on screen-test images before wiring up the backend
- Keep the backend minimal: FastAPI + SQLite, no ORM overhead
- Each phase has a clear exit criteria; don't move on until it's met

---

## Testing Strategy

**Screen-based testing (no laser hardware needed)**

Display the generated test board (`cv/generate_board.py`) fullscreen on a computer screen. Mount the iPhone on a tripod pointing at the screen. Use a red pencil/brush tool in any photo editor app to draw a red dot on the board image — this simulates a laser dot.

Benefits:
- Red dot persists as long as needed (no timing pressure)
- Dot position is fully controlled — place it anywhere to test different scores
- No laser, no physical board needed during early development

Caveat: a screen-rendered red dot looks different from a real laser dot (less saturated, no overexposure bloom). HSV detection thresholds tuned against screen tests will need a second pass when real laser testing begins.

---

## Detection Model: One-Shot-Then-Stop

The app does not run continuous detection. Instead it uses an explicit arm/disarm cycle:

```
IDLE ──[Ready]──► ARMED ──[dot detected]──► RESULT ──[Ready]──► ARMED
                     │
                  [scanning live feed]
```

- **IDLE**: camera preview is live but no detection runs
- **ARMED**: app scans every frame for a red dot; stops as soon as one is found
- **RESULT**: score is displayed; detection is paused until user taps Ready again

This matches real shooting (one trigger pull = one committed shot) and avoids all debouncing complexity. The persistent screen dot won't cause double-counting because the app disarms immediately after the first detection.

---

## Phase 0 — Test Setup

Before writing app code, confirm the test scenario works physically.

- [ ] Open `cv/generate_board.py` output fullscreen on a computer screen
- [ ] Mount iPhone on a tripod pointing at the screen with the full board visible
- [ ] Draw a red dot in a photo editor app over the board image
- [ ] Take a screenshot/photo and confirm the board corners and red dot are both clearly visible

**Exit criteria:** a photo or screenshot where all 4 ArUco corners and the red dot are distinguishable.

---

## Phase 1 — iPhone App: Red Dot Detection Only

Goal: a SwiftUI app that monitors the camera feed, detects a red dot, stops on the first detection, and displays the captured frame with the dot highlighted. No backend, no scoring, no ArUco. Just validate that red dot detection works on the iPhone.

```
ios/ShootingGame/
  ShootingGameApp.swift   # @main entry point
  ContentView.swift       # UI + AppViewModel (state machine)
  CameraManager.swift     # AVFoundation session + frame delivery
  RedDotDetector.swift    # per-frame RGB pixel scan → dot centroid
```

No OpenCV needed for this phase — detection uses direct pixel buffer scanning via CoreVideo.

### State machine

```
IDLE ──[Ready]──► ARMED ──[dot detected]──► RESULT ──[Ready]──► ARMED
                     │
              [scanning every frame]
```

- **IDLE**: camera preview live, "Ready" button shown
- **ARMED**: every camera frame is passed through `RedDotDetector`; stops on first hit
- **RESULT**: captured frame shown fullscreen, green circle overlaid on detected dot position, "Ready" button to re-arm

### 1a — Camera setup

- [x] `CameraManager.swift` — AVFoundation session, BGRA pixel buffer output, portrait orientation
- [ ] Create Xcode project (iOS, SwiftUI), add the 4 source files
- [ ] Add `NSCameraUsageDescription` to Info.plist

### 1b — Red dot detector

- [x] `RedDotDetector.swift` — scans CVPixelBuffer for pixels where R channel dominates (R > threshold, R − G > dominance, R − B > dominance); returns centroid of the largest qualifying cluster

Tunable thresholds (adjust for screen vs. laser):
- `minRedValue`: R channel floor (default 150)
- `minRedDominance`: how much R must exceed G and B (default 80)
- `minClusterSize` / `maxClusterSize`: blob size bounds (default 20–3000 px²)

### 1c — UI & state machine

- [x] `ContentView.swift` — three views for IDLE / ARMED / RESULT states
- [ ] Build and run on device
- [ ] Point at screen showing test board, draw red dot in photo editor
- [ ] Confirm: app detects dot → shows captured frame → green circle on dot

### 1d — Threshold tuning

- [ ] Test across different screen brightness levels
- [ ] Test with dot at different positions (center, edges, on dark ring vs. light ring background)
- [ ] Adjust `minRedValue` and `minRedDominance` in `RedDotDetector` until detection is reliable with no false positives
- [ ] Note the final threshold values — they will seed the backend's OpenCV HSV thresholds

**Exit criteria:** app reliably detects a red dot drawn on-screen across 5+ positions with no false positives in between shots.

---

## Phase 2 — Backend API

Goal: FastAPI server that accepts JPEG frames, runs the same CV pipeline in Python, and persists game/shot data. iPhone app is updated to POST frames to backend instead of doing CV on-device.

### 2a — Project scaffold

```
backend/
  main.py          # FastAPI app + route registration
  database.py      # SQLite connection + schema creation
  models.py        # Pydantic request/response schemas
  cv_pipeline.py   # CV logic ported from cv/detect.py
  requirements.txt
```

- [ ] Set up FastAPI + uvicorn
- [ ] SQLite schema: Game, Round, Shot tables (raw sqlite3, no ORM)
- [ ] Port `detect.py` CV logic into `cv_pipeline.py` as callable functions

### 2b — Game & round endpoints

- [ ] `POST /games` — create game, return `{game_id}`
- [ ] `GET /games/:id` — game + nested rounds + shots
- [ ] `POST /games/:id/rounds` — start round, return `{round_id}`
- [ ] `PATCH /rounds/:id/end` — set `ended_at`

### 2c — Shot detection endpoint

- [ ] `POST /rounds/:id/detect`
  - Accept `multipart/form-data` JPEG
  - Run `cv_pipeline.process_frame(jpeg_bytes)` → `{score, x, y, distance_px}` or `None`
  - Return `{detected: false}` if no dot found (don't insert)
  - Return `{detected: true, score, x, y}` and insert Shot row if valid
- [ ] `GET /rounds/:id/shots` — all shots for a round

### 2d — Validation

- [ ] Python test script: create game → round → POST 5 saved images → assert scores match

**Exit criteria:** full game cycle works via curl or Python requests.

---

## Phase 3 — iPhone App: Backend Integration

Switch the app from on-device CV to posting frames to the backend. On-device detection (Phase 1) becomes the Stage 1 trigger only.

- [ ] Settings screen: backend IP + port, active game/round IDs (stored in `UserDefaults`)
- [ ] When dot trigger fires: capture frame as JPEG, POST to `/rounds/:id/detect`
- [ ] Parse backend response for score; display same RESULT UI as Phase 1
- [ ] Game flow: create game, start/end rounds from within the app via API calls
- [ ] Graceful fallback: if backend unreachable, show error and stay in ARMED state

**Exit criteria:** full flow — draw dot on screen → score on iPhone → shot stored in backend DB.

---

## Phase 4 — Frontend Web App

Goal: browser display showing current game state and a live annotated target.

### 4a — Scaffold

```
frontend/
  index.html
  app.js
  style.css
```

Plain HTML + Canvas, no build step.

### 4b — Target canvas

- [ ] Draw 10 concentric rings on `<canvas>` matching canonical geometry (normalized coords → canvas pixels)
- [ ] Render each shot as a dot at `(x, y)` normalized position
  - Score 8–10: green, 5–7: yellow, 1–4: red, 0: gray outside rings

### 4c — Game state panel

- [ ] Player name, round number, round score, cumulative score
- [ ] Shot list: score + timestamp per shot

### 4d — Live updates

- [ ] Poll `GET /rounds/:id/shots` every 1.5s; re-render canvas on change
- [ ] `?game_id=X&round_id=Y` query params encode the active session in the URL

**Exit criteria:** draw dot on screen → dot appears on web canvas within 3 seconds.

---

## Phase 5 — Polish & Hardening

- [ ] Tune HSV thresholds against real laser dot (likely needs higher brightness/saturation floor than screen dot)
- [ ] Backend: reject duplicate shots within 1s window per round (guard against network retries)
- [ ] Web: flash animation when new shot lands
- [ ] Test in varied lighting: overhead fluorescent, natural daylight, dim
- [ ] Web: "review mode" — step through shots one by one with timestamps
- [ ] Backend: `GET /games` listing for history

---

## Dependency Order

```
Phase 0 (screen test setup)
    ↓
Phase 1 (iPhone app, on-device CV) ← fully working standalone app
    ↓
Phase 2 (backend API)
    ↓
Phase 3 (iPhone → backend integration)
    ↓
Phase 4 (web frontend)       ← can start in parallel with Phase 3
    ↓
Phase 5 (polish + real laser)
```

---

## File Structure (final)

```
shooting-game/
  SPEC.md
  PLAN.md
  cv/
    generate_board.py       # test image generator
    detect.py               # standalone Python CV prototype
    requirements.txt
  backend/
    main.py
    database.py
    models.py
    cv_pipeline.py
    requirements.txt
  frontend/
    index.html
    app.js
    style.css
  ios/
    ShootingGame.xcodeproj
    ShootingGame/
      ContentView.swift
      CameraManager.swift
      BoardDetector.swift
      DotDetector.swift
      Scorer.swift
      OpenCVWrapper.h
      OpenCVWrapper.mm
```
