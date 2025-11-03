from __future__ import annotations

import logging
import os
import shlex
import signal
import subprocess
import sys
from contextlib import suppress
from pathlib import Path
from logging.handlers import TimedRotatingFileHandler
from subprocess import Popen
from time import perf_counter
from typing import Any, Optional

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from rcon.source import Client as RconClient
import psutil
from dotenv import load_dotenv
from src.schemas import StartBody, StopBody

BACKEND_DIR = Path(__file__).resolve().parents[1]
ROOT_DIR = BACKEND_DIR.parent
load_dotenv(dotenv_path=BACKEND_DIR / ".env", override=False)
load_dotenv(dotenv_path=BACKEND_DIR / ".env.local", override=False)

app = FastAPI(title="ASA Control API")

# --------------------
# Config (env overrides)
# --------------------
API_KEY = os.getenv("ASA_API_KEY", "supersecret")  # simple auth for your React app
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
DEFAULT_ORIGINS = "http://localhost:3000,http://127.0.0.1:3000"
ALLOWED_ORIGINS = [
    origin.strip()
    for origin in os.getenv("ASA_ALLOWED_ORIGINS", DEFAULT_ORIGINS).split(",")
    if origin.strip()
]
ALLOWED_ORIGIN_REGEX = os.getenv("ASA_ALLOWED_ORIGIN_REGEX", "")
ALLOW_ALL_ORIGINS = os.getenv("ASA_ALLOW_ALL_ORIGINS", "").lower() in {"1", "true", "yes"}

LOG_LEVEL = os.getenv("ASA_LOG_LEVEL", "INFO").upper()
LOG_FORMAT = "%(asctime)s %(levelname)s [%(name)s] %(message)s"
root_logger = logging.getLogger()
root_logger.setLevel(LOG_LEVEL)

if not any(isinstance(h, logging.StreamHandler) for h in root_logger.handlers):
    stream_handler = logging.StreamHandler(sys.stdout)
    stream_handler.setFormatter(logging.Formatter(LOG_FORMAT))
    root_logger.addHandler(stream_handler)
else:
    for handler in root_logger.handlers:
        if isinstance(handler, logging.StreamHandler):
            handler.setFormatter(logging.Formatter(LOG_FORMAT))

log_dir_default = ROOT_DIR / "logs"
LOG_DIR = Path(os.getenv("ASA_LOG_DIR", str(log_dir_default)))
LOG_DIR.mkdir(parents=True, exist_ok=True)
log_file = LOG_DIR / "backend.log"

if not any(isinstance(h, TimedRotatingFileHandler) for h in root_logger.handlers):
    file_handler = TimedRotatingFileHandler(
        log_file,
        when="midnight",
        backupCount=1,
        encoding="utf-8",
    )
    file_handler.setFormatter(logging.Formatter(LOG_FORMAT))
    root_logger.addHandler(file_handler)

logger = logging.getLogger("asa.server")
logger.setLevel(LOG_LEVEL)
logger.propagate = True

STATE_DIR = ROOT_DIR / ".run"
STATE_DIR.mkdir(parents=True, exist_ok=True)
SERVER_PID_FILE = STATE_DIR / "ark-server.pid"

cors_kwargs: dict[str, Any] = {
    "allow_methods": ["*"],
    "allow_headers": ["*"],
    "allow_credentials": False,
}
if ALLOW_ALL_ORIGINS:
    cors_kwargs["allow_origins"] = ["*"]
elif ALLOWED_ORIGIN_REGEX:
    cors_kwargs["allow_origin_regex"] = ALLOWED_ORIGIN_REGEX
elif ALLOWED_ORIGINS:
    cors_kwargs["allow_origins"] = ALLOWED_ORIGINS
else:
    cors_kwargs["allow_origins"] = ["*"]

app.add_middleware(CORSMiddleware, **cors_kwargs)


@app.middleware("http")
async def log_requests(request: Request, call_next):
    start = perf_counter()
    client = request.client.host if request.client else "-"
    logger.debug("HTTP %s %s from %s received", request.method, request.url.path, client)
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
        self._pid: Optional[int] = self._load_pid()
        if self._pid is not None and not self._process_alive(self._pid):
            self._clear_pid_file()
            self._pid = None

    @staticmethod
    def _process_alive(pid: int) -> bool:
        try:
            return psutil.pid_exists(pid)
        except Exception:
            return False

    @staticmethod
    def _load_pid() -> Optional[int]:
        try:
            data = SERVER_PID_FILE.read_text(encoding="ascii").strip()
            if data:
                return int(data)
        except (FileNotFoundError, ValueError):
            return None
        return None

    @staticmethod
    def _write_pid(pid: int) -> None:
        SERVER_PID_FILE.write_text(str(pid), encoding="ascii")

    @staticmethod
    def _clear_pid_file() -> None:
        with suppress(FileNotFoundError):
            SERVER_PID_FILE.unlink()

    def _ensure_proc(self) -> Popen[bytes]:
        proc = self._p
        if proc is None:
            raise RuntimeError("Server process not running")
        return proc

    def is_running(self) -> bool:
        proc = self._p
        if proc is not None and proc.poll() is None:
            return True
        if self._pid is None:
            return False
        if self._process_alive(self._pid):
            return True
        self._clear_pid_file()
        self._pid = None
        return False

    def pid(self) -> Optional[int]:
        if self.is_running():
            if self._p is not None and self._p.poll() is None:
                self._pid = self._p.pid
            return self._pid
        return None

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
        if self._p.pid is not None:
            self._pid = self._p.pid
            self._write_pid(self._pid)

    def kill(self) -> None:
        if not self.is_running():
            return
        try:
            if self._p is not None and self._p.poll() is None:
                proc = self._ensure_proc()
                if sys.platform == "win32":
                    proc.send_signal(signal.CTRL_BREAK_EVENT)  # graceful-ish
                proc.terminate()
                with suppress(Exception):
                    proc.kill()
            elif self._pid is not None:
                try:
                    ps_proc = psutil.Process(self._pid)
                    if sys.platform == "win32":
                        with suppress(Exception):
                            ps_proc.send_signal(signal.CTRL_BREAK_EVENT)  # type: ignore[arg-type]
                    ps_proc.terminate()
                    with suppress(Exception):
                        ps_proc.kill()
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    pass
        finally:
            self._p = None
            self._pid = None
            self._clear_pid_file()

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
def stop_server(body: StopBody | None = None, x_api_key: Optional[str] = Header(default=None)):
    require_key(x_api_key)
    if body is None:
        body = StopBody()

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
    logger.debug("Status polled (running=%s, pid=%s)", proc.is_running(), proc.pid())
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
