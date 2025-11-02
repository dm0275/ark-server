from __future__ import annotations

import logging
import os
import shlex
import signal
import subprocess
import sys
from contextlib import suppress
from pathlib import Path
from subprocess import Popen
from time import perf_counter
from typing import Any, Optional

from fastapi import FastAPI, Header, HTTPException, Request
from rcon.source import Client as RconClient

from src.schemas import StartBody, StopBody

app = FastAPI(title="ASA Control API")

# --------------------
# Config (env overrides)
# --------------------
API_KEY = os.getenv("ASA_API_KEY", "change-me")  # simple auth for your React app
WORKING_DIR = Path(os.getenv("ASA_WORKING_DIR", r"C:\arkascendedserver\ShooterGame\Binaries\Win64"))
EXE_PATH = WORKING_DIR / "ArkAscendedServer.exe"

# Defaults (can be overridden by /start body)
DEFAULTS: dict[str, Any] = {
    "Map": "TheIsland_WP",
    "SessionName": "My ASA Server",
    "MaxPlayers": 16,
    "GamePort": 7777,
    "QueryPort": 27015,
    "RCONPort": 27020,  # set to None to omit
    "ServerPassword": "",
    "ServerAdminPassword": "ChangeMeAdmin!",
    "NoBattlEye": True,
    "Mods": [],  # e.g. ["123", "456"]
    "ExtraArgs": ["-server", "-log"],
}

# RCON config (must match server settings)
RCON_HOST = os.getenv("ASA_RCON_HOST", "127.0.0.1")

LOG_LEVEL = os.getenv("ASA_LOG_LEVEL", "INFO").upper()
if not logging.getLogger().handlers:
    logging.basicConfig(
        level=LOG_LEVEL,
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    )
else:
    logging.getLogger().setLevel(LOG_LEVEL)

logger = logging.getLogger("asa.server")


@app.middleware("http")
async def log_requests(request: Request, call_next):
    start = perf_counter()
    client = request.client.host if request.client else "-"
    try:
        response = await call_next(request)
    except Exception:
        duration_ms = (perf_counter() - start) * 1000
        logger.exception(
            "HTTP %s %s from %s failed after %.2f ms",
            request.method,
            request.url.path,
            client,
            duration_ms,
        )
        raise

    duration_ms = (perf_counter() - start) * 1000
    logger.info(
        "HTTP %s %s from %s -> %s (%.2f ms)",
        request.method,
        request.url.path,
        client,
        response.status_code,
        duration_ms,
    )
    return response

# --------------------
# Simple process holder
# --------------------
class ServerProcess:
    def __init__(self) -> None:
        self._p: Popen[bytes] | None = None

    def _ensure_proc(self) -> Popen[bytes]:
        proc = self._p
        if proc is None:
            raise RuntimeError("Server process not running")
        return proc

    def is_running(self) -> bool:
        proc = self._p
        return proc is not None and (proc.poll() is None)

    def pid(self) -> Optional[int]:
        proc = self._p
        return proc.pid if proc is not None and proc.poll() is None else None

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
            creationflags=creationflags,
        )

    def kill(self) -> None:
        if not self.is_running():
            return
        proc = self._ensure_proc()
        try:
            if sys.platform == "win32":
                proc.send_signal(signal.CTRL_BREAK_EVENT)  # graceful-ish
            proc.terminate()
        except Exception:
            pass
        finally:
            with suppress(Exception):
                proc.kill()
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
    cfg: dict[str, Any] = DEFAULTS.copy()
    for k, v in body.model_dump(exclude_none=True).items():
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
    rcon_port = body.RconPort if body.RconPort is not None else DEFAULTS["RCONPort"]
    rcon_pass = DEFAULTS["ServerAdminPassword"]
    if rcon_port is not None and rcon_pass:
        try:
            rcon_send("saveworld", rcon_port, rcon_pass)
            rcon_send("DoExit", rcon_port, rcon_pass)
            return {"ok": True, "method": "rcon"}
        except Exception:
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
                rcon_send("DoExit", DEFAULTS["RCONPort"], DEFAULTS["ServerAdminPassword"])
        except Exception:
            proc.kill()
    # start with defaults again
    args = build_args(
        Map=DEFAULTS["Map"],
        SessionName=DEFAULTS["SessionName"],
        MaxPlayers=DEFAULTS["MaxPlayers"],
        GamePort=DEFAULTS["GamePort"],
        QueryPort=DEFAULTS["QueryPort"],
        RCONPort=DEFAULTS["RCONPort"],
        ServerPassword=DEFAULTS["ServerPassword"],
        ServerAdminPassword=DEFAULTS["ServerAdminPassword"],
        NoBattlEye=DEFAULTS["NoBattlEye"],
        Mods=DEFAULTS["Mods"],
        ExtraArgs=DEFAULTS["ExtraArgs"],
    )
    proc.start(args)
    return {"ok": True, "pid": proc.pid()}
