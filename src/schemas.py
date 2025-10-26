from typing import Optional

from pydantic import BaseModel


# --------------------
# Schemas
# --------------------
class StartBody(BaseModel):
    Map: Optional[str] = None
    SessionName: Optional[str] = None
    MaxPlayers: Optional[int] = None
    GamePort: Optional[int] = None
    QueryPort: Optional[int] = None
    RCONPort: Optional[int] = None  # set null to omit
    ServerPassword: Optional[str] = None
    ServerAdminPassword: Optional[str] = None
    NoBattlEye: Optional[bool] = None
    Mods: Optional[list[str]] = None  # ["123","456"] or pass strings and split in React
    ExtraArgs: Optional[list[str]] = None

class StopBody(BaseModel):
    # Optional: override RCON creds at call-time (usually not needed)
    RconPort: Optional[int] = None
    RconPassword: Optional[str] = None
    ForceKillAfterSeconds: int = 10
