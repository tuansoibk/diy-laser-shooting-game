from pydantic import BaseModel
from typing import Optional, List

class GameCreate(BaseModel):
    player_name: str = "Player"

class GameResponse(BaseModel):
    id: int
    player_name: str
    created_at: str

class RoundResponse(BaseModel):
    id: int
    game_id: int
    round_number: int
    started_at: str
    ended_at: Optional[str]

class ShotResponse(BaseModel):
    id: int
    round_id: int
    score: int
    x: float
    y: float
    distance_px: float
    created_at: str

class GameDetail(BaseModel):
    id: int
    player_name: str
    created_at: str
    rounds: List[RoundResponse]

class RoundDetail(BaseModel):
    id: int
    game_id: int
    round_number: int
    started_at: str
    ended_at: Optional[str]
    shots: List[ShotResponse]

class DetectResponse(BaseModel):
    detected: bool
    multiple_dots: bool = False
    score: Optional[int] = None
    x: Optional[float] = None
    y: Optional[float] = None
    distance_px: Optional[float] = None
    shot_id: Optional[int] = None
