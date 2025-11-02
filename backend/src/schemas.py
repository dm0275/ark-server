from typing import Optional

from pydantic import BaseModel, field_validator


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

    @field_validator("Mods", mode="before")
    def _coerce_mods(cls, v):
        if isinstance(v, str):
            return [part.strip() for part in v.split(",") if part.strip()]
        return v

class StopBody(BaseModel):
    # Optional: override RCON creds at call-time (usually not needed)
    RconPort: Optional[int] = None
    RconPassword: Optional[str] = None
    ForceKillAfterSeconds: int = 10
