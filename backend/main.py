import os
from fastapi import FastAPI, HTTPException, UploadFile, File, Form
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from contextlib import asynccontextmanager

from database import init_db, get_conn
from models import (
    GameCreate, GameResponse, GameDetail,
    RoundResponse, RoundDetail,
    ShotResponse, DetectResponse, CurrentSession, List, Optional,
)
from cv_pipeline import process_frame, debug_frame


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    yield

app = FastAPI(title="Shooting Game API", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Current session
# ---------------------------------------------------------------------------

@app.get("/current", response_model=CurrentSession)
def get_current():
    with get_conn() as conn:
        game = conn.execute(
            "SELECT * FROM game ORDER BY id DESC LIMIT 1"
        ).fetchone()
        if not game:
            raise HTTPException(404, "No games found")

        round_row = conn.execute(
            "SELECT * FROM round WHERE game_id = ? ORDER BY id DESC LIMIT 1",
            (game["id"],),
        ).fetchone()

    result = {"game_id": game["id"], "player_name": game["player_name"]}
    if round_row:
        result["round_id"]     = round_row["id"]
        result["round_number"] = round_row["round_number"]
        result["round_ended"]  = round_row["ended_at"] is not None
    return result


# ---------------------------------------------------------------------------
# Games
# ---------------------------------------------------------------------------

@app.post("/games", response_model=GameResponse, status_code=201)
def create_game(body: GameCreate):
    with get_conn() as conn:
        cur = conn.execute(
            "INSERT INTO game (player_name) VALUES (?) RETURNING id, player_name, created_at",
            (body.player_name,),
        )
        row = cur.fetchone()
    return dict(row)


@app.get("/games/{game_id}", response_model=GameDetail)
def get_game(game_id: int):
    with get_conn() as conn:
        game = conn.execute("SELECT * FROM game WHERE id = ?", (game_id,)).fetchone()
        if not game:
            raise HTTPException(404, "Game not found")

        rounds = conn.execute(
            "SELECT * FROM round WHERE game_id = ? ORDER BY round_number", (game_id,)
        ).fetchall()

    return {**dict(game), "rounds": [dict(r) for r in rounds]}


# ---------------------------------------------------------------------------
# Rounds
# ---------------------------------------------------------------------------

@app.post("/games/{game_id}/rounds", response_model=RoundResponse, status_code=201)
def create_round(game_id: int):
    with get_conn() as conn:
        if not conn.execute("SELECT 1 FROM game WHERE id = ?", (game_id,)).fetchone():
            raise HTTPException(404, "Game not found")

        next_num = (conn.execute(
            "SELECT COALESCE(MAX(round_number), 0) + 1 FROM round WHERE game_id = ?", (game_id,)
        ).fetchone()[0])

        cur = conn.execute(
            "INSERT INTO round (game_id, round_number) VALUES (?, ?) "
            "RETURNING id, game_id, round_number, started_at, ended_at",
            (game_id, next_num),
        )
        row = cur.fetchone()
    return dict(row)


@app.patch("/rounds/{round_id}/end", response_model=RoundResponse)
def end_round(round_id: int):
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM round WHERE id = ?", (round_id,)).fetchone()
        if not row:
            raise HTTPException(404, "Round not found")
        if row["ended_at"]:
            raise HTTPException(400, "Round already ended")

        conn.execute(
            "UPDATE round SET ended_at = CURRENT_TIMESTAMP WHERE id = ?", (round_id,)
        )
        row = conn.execute("SELECT * FROM round WHERE id = ?", (round_id,)).fetchone()
    return dict(row)


@app.get("/rounds/{round_id}", response_model=RoundDetail)
def get_round(round_id: int):
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM round WHERE id = ?", (round_id,)).fetchone()
        if not row:
            raise HTTPException(404, "Round not found")
        shots = conn.execute(
            "SELECT * FROM shot WHERE round_id = ? ORDER BY created_at", (round_id,)
        ).fetchall()
    return {**dict(row), "shots": [dict(s) for s in shots]}


# ---------------------------------------------------------------------------
# Shots / detection
# ---------------------------------------------------------------------------

@app.post("/detect", response_model=DetectResponse)
async def detect_current(
    frame: UploadFile = File(...),
    hint_x: Optional[float] = Form(None),
    hint_y: Optional[float] = Form(None),
):
    """
    Used by the iOS app. Finds the current active round automatically so
    the app does not need to know anything about games or rounds.
    """
    with get_conn() as conn:
        game = conn.execute(
            "SELECT * FROM game ORDER BY id DESC LIMIT 1"
        ).fetchone()
        if not game:
            raise HTTPException(404, "No active game — create one from the web interface")

        round_row = conn.execute(
            "SELECT * FROM round WHERE game_id = ? AND ended_at IS NULL ORDER BY id DESC LIMIT 1",
            (game["id"],),
        ).fetchone()
        if not round_row:
            raise HTTPException(404, "No active round — start a round from the web interface")

        round_id = round_row["id"]

    jpeg_bytes = await frame.read()
    result = process_frame(jpeg_bytes, hint_x=hint_x, hint_y=hint_y)

    if result is None:
        return DetectResponse(detected=False)
    if result.get("multiple_dots"):
        return DetectResponse(detected=False, multiple_dots=True)

    with get_conn() as conn:
        cur = conn.execute(
            "INSERT INTO shot (round_id, score, x, y, distance_px) VALUES (?, ?, ?, ?, ?) "
            "RETURNING id",
            (round_id, result["score"], result["x"], result["y"], result["distance_px"]),
        )
        shot_id = cur.fetchone()["id"]

    return DetectResponse(detected=True, shot_id=shot_id, **result)


@app.post("/rounds/{round_id}/detect", response_model=DetectResponse)
async def detect_shot(
    round_id: int,
    frame: UploadFile = File(...),
    hint_x: Optional[float] = Form(None),
    hint_y: Optional[float] = Form(None),
):
    with get_conn() as conn:
        round_row = conn.execute("SELECT * FROM round WHERE id = ?", (round_id,)).fetchone()
        if not round_row:
            raise HTTPException(404, "Round not found")
        if round_row["ended_at"]:
            raise HTTPException(400, "Round has already ended")

    jpeg_bytes = await frame.read()
    result = process_frame(jpeg_bytes, hint_x=hint_x, hint_y=hint_y)

    if result is None:
        return DetectResponse(detected=False)

    if result.get("multiple_dots"):
        return DetectResponse(detected=False, multiple_dots=True)

    with get_conn() as conn:
        cur = conn.execute(
            "INSERT INTO shot (round_id, score, x, y, distance_px) VALUES (?, ?, ?, ?, ?) "
            "RETURNING id",
            (round_id, result["score"], result["x"], result["y"], result["distance_px"]),
        )
        shot_id = cur.fetchone()["id"]

    return DetectResponse(detected=True, shot_id=shot_id, **result)


@app.get("/rounds/{round_id}/shots", response_model=List[ShotResponse])
def get_shots(round_id: int):
    with get_conn() as conn:
        if not conn.execute("SELECT 1 FROM round WHERE id = ?", (round_id,)).fetchone():
            raise HTTPException(404, "Round not found")
        rows = conn.execute(
            "SELECT * FROM shot WHERE round_id = ? ORDER BY created_at", (round_id,)
        ).fetchall()
    return [dict(r) for r in rows]


# ---------------------------------------------------------------------------
# Debug
# ---------------------------------------------------------------------------

@app.post("/debug/detect")
async def debug_detect(frame: UploadFile = File(...)):
    """
    Drop-in replacement for /rounds/:id/detect that returns full pipeline
    diagnostics instead of persisting a shot.

    Response fields:
      stage        — "decode" | "aruco" | "dots" | "ok"
      aruco_ids    — ArUco marker IDs that were found (should be [0,1,2,3])
      contours     — every red blob found, with area / circularity / hsv /
                     passed / fail_reason
      result       — same dict as process_frame, or null
      debug_image  — base64 JPEG: left half = warped board with contours
                     annotated, right half = HSV mask
    """
    jpeg_bytes = await frame.read()
    return debug_frame(jpeg_bytes)


# ---------------------------------------------------------------------------
# Frontend — must be mounted last so API routes take priority
# ---------------------------------------------------------------------------

_FRONTEND = os.path.join(os.path.dirname(__file__), "..", "frontend")
app.mount("/", StaticFiles(directory=_FRONTEND, html=True), name="frontend")
