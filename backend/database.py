import sqlite3
import os
from contextlib import contextmanager

DB_PATH = os.path.join(os.path.dirname(__file__), "game.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS game (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    player_name TEXT    NOT NULL DEFAULT 'Player',
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS round (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    game_id      INTEGER NOT NULL REFERENCES game(id),
    round_number INTEGER NOT NULL,
    started_at   DATETIME DEFAULT CURRENT_TIMESTAMP,
    ended_at     DATETIME
);

CREATE TABLE IF NOT EXISTS shot (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    round_id    INTEGER NOT NULL REFERENCES round(id),
    score       INTEGER NOT NULL,
    x           REAL    NOT NULL,
    y           REAL    NOT NULL,
    distance_px REAL    NOT NULL,
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP
);
"""

def init_db():
    with get_conn() as conn:
        conn.executescript(SCHEMA)

@contextmanager
def get_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
