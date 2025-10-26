import os
import shlex
import signal
import subprocess
import sys
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Header, HTTPException
from rcon.source import Client as RconClient

from src.schemas import StartBody, StopBody

app = FastAPI(title="ASA Control API")

# --------------------
# Config (env overrides)
# --------------------
API_KEY       = os.getenv("ASA_API_KEY", "change-me")   # simple auth for your React app
WORKING_DIR   = Path(os.getenv("ASA_WORKING_DIR", r"E:\arkascendedserver\ShooterGame\Binaries\Win64"))
EXE_PATH      = WORKING_DIR / "ArkAscendedServer.exe"

# Defaults (can be overridden by /start body)
DEFAULTS = {
    "Map": "TheIsland_WP",
    "SessionName": "My ASA Server",
    "MaxPlayers": 16,
    "GamePort": 7777,
    "QueryPort": 27015,
    "RCONPort": 27020,                 # set to None to omit
    "ServerPassword": "",
    "ServerAdminPassword": "ChangeMeAdmin!",
    "NoBattlEye": True,
    "Mods": [],                        # e.g. ["123","456"]
    "ExtraArgs": ["-server","-log"],
}

# RCON config (must match server settings)
RCON_HOST = os.getenv("ASA_RCON_HOST", "127.0.0.1")

# --------------------
# Simple process holder
# --------------------
class ServerProcess:
    def __init__(self) -> None:
        self._p: Optional[subprocess.Popen] = None

    def is_running(self) -> bool:
        return self._p is not None and (self._p.poll() is None)

    def pid(self) -> Optional[int]:
        return self._p.pid if self.is_running() else None

    def start(self, args: list[str]) -> None:
        if self.is_running():
            raise RuntimeError("Server already running")
        # Start detached so the HTTP request can return immediately
        creationflags = 0
        if sys.platform == "win32":
            CREATE_NEW_PROCESS_GROUP = 0x00000200
            DETACHED_PROCESS = 0x00000008
            creationflags = CREATE_NEW_PROCESS_GROUP | DETACHED_PROCESS

        self._p = subprocess.Popen(
            [str(EXE_PATH), *args],
            cwd=str(WORKING_DIR),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.STDOUT,
            creationflags=creationflags
        )

    def kill(self) -> None:
        if not self.is_running():
            return
        try:
            if sys.platform == "win32":
                self._p.send_signal(signal.CTRL_BREAK_EVENT)  # graceful-ish
            self._p.terminate()
        except Exception:
            pass
        finally:
            try:
                self._p.kill()
            except Exception:
                pass
            self._p = None

proc = ServerProcess()

# --------------------
# Helpers
# --------------------
def require_key(x_api_key: Optional[str]):
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="unauthorized")

def build_args(
        Map: str,
        SessionName: str,
        MaxPlayers: int,
        GamePort: int,
        QueryPort: int,
        RCONPort: Optional[int],
        ServerPassword: str,
        ServerAdminPassword: str,
        NoBattlEye: bool,
        Mods: list[str],
        ExtraArgs: list[str],
) -> list[str]:
    # URL-style block; IMPORTANT: space before 'listen'
    parts: list[str] = []
    parts += [Map]
    parts += [f"?SessionName={shlex.quote(SessionName).replace(' ', '%20')}"]
    parts += [f"?Port={GamePort}"]
    parts += [f"?QueryPort={QueryPort}"]
    parts += [f"?MaxPlayers={MaxPlayers}"]
    if ServerPassword:
        parts += [f"?ServerPassword={ServerPassword}"]
    if ServerAdminPassword:
        parts += [f"?ServerAdminPassword={ServerAdminPassword}"]
    if RCONPort is not None:
        parts += [f"?RCONEnabled=True", f"?RCONPort={RCONPort}"]

    url_arg = ("".join(parts) + " listen").strip()  # <- ensure space before 'listen'

    args: list[str] = [url_arg]
    if Mods:
        args += [f"-mods={','.join(Mods)}"]  # ASA auto-downloads these on boot
    if NoBattlEye:
        args += ["-NoBattlEye"]
    args += list(ExtraArgs)
    return args

def rcon_send(command: str, port: int, password: str) -> str:
    with RconClient(RCON_HOST, port, passwd=password, timeout=3) as rcon:
        return rcon.run(command)


# --------------------
# Endpoints
# --------------------
@app.post("/start")
def start_server(body: StartBody, x_api_key: Optional[str] = Header(default=None)):
    require_key(x_api_key)

    if not EXE_PATH.exists():
        raise HTTPException(status_code=500, detail=f"ArkAscendedServer.exe not found at {EXE_PATH}")
    if proc.is_running():
        raise HTTPException(status_code=409, detail=f"Server already running (pid={proc.pid()})")

    # merge defaults with body
    cfg = DEFAULTS.copy()
    for k, v in body.dict(exclude_none=True).items():
        cfg[k] = v

    args = build_args(
        Map=cfg["Map"],
        SessionName=cfg["SessionName"],
        MaxPlayers=int(cfg["MaxPlayers"]),
        GamePort=int(cfg["GamePort"]),
        QueryPort=int(cfg["QueryPort"]),
        RCONPort=cfg["RCONPort"],
        ServerPassword=cfg["ServerPassword"],
        ServerAdminPassword=cfg["ServerAdminPassword"],
        NoBattlEye=bool(cfg["NoBattlEye"]),
        Mods=[str(x) for x in (cfg["Mods"] or [])],
        ExtraArgs=[str(x) for x in (cfg["ExtraArgs"] or [])],
    )
    proc.start(args)
    return {"ok": True, "pid": proc.pid(), "args": args}

@app.post("/stop")
def stop_server(body: StopBody, x_api_key: Optional[str] = Header(default=None)):
    require_key(x_api_key)

    if not proc.is_running():
        return {"ok": True, "already": "stopped"}

    # Try graceful RCON if we know the port/password
    rcon_port = body.RconPort or (DEFAULTS["RCONPort"] if DEFAULTS["RCONPort"] is not None else None)
    rcon_pass = DEFAULTS["ServerAdminPassword"]
    if rcon_port is not None and rcon_pass:
        try:
            rcon_send("saveworld", rcon_port, rcon_pass)
            rcon_send("DoExit",    rcon_port, rcon_pass)
            return {"ok": True, "method": "rcon"}
        except Exception as e:
            # fall through to kill
            pass

    # Hard stop
    proc.kill()
    return {"ok": True, "method": "kill"}

@app.get("/status")
def status(x_api_key: Optional[str] = Header(default=None)):
    require_key(x_api_key)
    return {"running": proc.is_running(), "pid": proc.pid()}

@app.post("/restart")
def restart(x_api_key: Optional[str] = Header(default=None)):
    require_key(x_api_key)
    if proc.is_running():
        try:
            # graceful restart via RCON if possible
            if DEFAULTS["RCONPort"] is not None and DEFAULTS["ServerAdminPassword"]:
                rcon_send("saveworld", DEFAULTS["RCONPort"], DEFAULTS["ServerAdminPassword"])
                rcon_send("DoExit",    DEFAULTS["RCONPort"], DEFAULTS["ServerAdminPassword"])
        except Exception:
            proc.kill()
    # start with defaults again
    args = build_args(**{
        "Map": DEFAULTS["Map"],
        "SessionName": DEFAULTS["SessionName"],
        "MaxPlayers": DEFAULTS["MaxPlayers"],
        "GamePort": DEFAULTS["GamePort"],
        "QueryPort": DEFAULTS["QueryPort"],
        "RCONPort": DEFAULTS["RCONPort"],
        "ServerPassword": DEFAULTS["ServerPassword"],
        "ServerAdminPassword": DEFAULTS["ServerAdminPassword"],
        "NoBattlEye": DEFAULTS["NoBattlEye"],
        "Mods": DEFAULTS["Mods"],
        "ExtraArgs": DEFAULTS["ExtraArgs"],
    })
    proc.start(args)
    return {"ok": True, "pid": proc.pid()}
