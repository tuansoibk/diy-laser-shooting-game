import os
from fastapi import FastAPI, HTTPException, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from contextlib import asynccontextmanager

from database import init_db, get_conn
from models import (
    GameCreate, GameResponse, GameDetail,
    RoundResponse, RoundDetail,
    ShotResponse, DetectResponse, CurrentSession, List,
)
from cv_pipeline import process_frame


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
        if not round_row:
            raise HTTPException(404, "No rounds found for current game")

    return {
        "game_id":      game["id"],
        "player_name":  game["player_name"],
        "round_id":     round_row["id"],
        "round_number": round_row["round_number"],
        "round_ended":  round_row["ended_at"] is not None,
    }


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

@app.post("/rounds/{round_id}/detect", response_model=DetectResponse)
async def detect_shot(round_id: int, frame: UploadFile = File(...)):
    with get_conn() as conn:
        round_row = conn.execute("SELECT * FROM round WHERE id = ?", (round_id,)).fetchone()
        if not round_row:
            raise HTTPException(404, "Round not found")
        if round_row["ended_at"]:
            raise HTTPException(400, "Round has already ended")

    jpeg_bytes = await frame.read()
    result = process_frame(jpeg_bytes)

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
# Frontend — must be mounted last so API routes take priority
# ---------------------------------------------------------------------------

_FRONTEND = os.path.join(os.path.dirname(__file__), "..", "frontend")
app.mount("/", StaticFiles(directory=_FRONTEND, html=True), name="frontend")
