import { useEffect, useMemo, useState } from "react";
import "./app.css";

export default function ASAControlApp() {
    const API = import.meta.env.VITE_ASA_API_URL || "http://localhost:8000";
    const API_KEY = import.meta.env.VITE_ASA_API_KEY || "supersecret";
    const DEFAULT_SERVER_PASSWORD =
        import.meta.env.VITE_ASA_SERVER_PASSWORD !== undefined
            ? import.meta.env.VITE_ASA_SERVER_PASSWORD
            : "";
    const DEFAULT_ADMIN_PASSWORD =
        import.meta.env.VITE_ASA_ADMIN_PASSWORD !== undefined
            ? import.meta.env.VITE_ASA_ADMIN_PASSWORD
            : "ChangeMeAdmin!";

    const headers = useMemo(
        () => ({
            "Content-Type": "application/json",
            "x-api-key": API_KEY,
        }),
        [API_KEY]
    );

    const [status, setStatus] = useState({ running: false, pid: null, via: "" });
    const [busy, setBusy] = useState(false);
    const [sessionName, setSessionName] = useState("MyASAServer");
    const [mods, setMods] = useState("929578,953154,934231,1061361");
    const [serverPassword, setServerPassword] = useState(DEFAULT_SERVER_PASSWORD);
    const [adminPassword, setAdminPassword] = useState(DEFAULT_ADMIN_PASSWORD);
    const [maxPlayers, setMaxPlayers] = useState(16);
    const [noBE, setNoBE] = useState(true);
    const [rconCmd, setRconCmd] = useState("");
    const [toast, setToast] = useState("");

    async function api(path, opts = {}) {
        const r = await fetch(`${API}${path}`, { ...opts, headers });
        if (!r.ok) {
            const text = await r.text();
            throw new Error(text || r.statusText);
        }
        return r.json();
    }

    async function refresh() {
        try {
            const j = await api("/status");
            setStatus({ running: !!j.running, pid: j.pid || null, via: j.via || "" });
        } catch (e) {
            setToast(`Status error: ${e.message}`);
        }
    }

    async function start() {
        setBusy(true);
        try {
            const body = {
                SessionName: sessionName,
                Mods: mods,
                NoBattlEye: noBE,
                MaxPlayers: Number(maxPlayers) || 0,
                ServerPassword: serverPassword,
                ServerAdminPassword: adminPassword,
            };
            await api("/start", { method: "POST", body: JSON.stringify(body) });
            setToast("Server starting…");
            setTimeout(refresh, 1200);
        } catch (e) {
            setToast(`Start error: ${e.message}`);
        } finally {
            setBusy(false);
        }
    }

    async function stop() {
        setBusy(true);
        try {
            await api("/stop", { method: "POST" });
            setToast("Server stopping…");
            setTimeout(refresh, 1500);
        } catch (e) {
            setToast(`Stop error: ${e.message}`);
        } finally {
            setBusy(false);
        }
    }

    async function restart() {
        setBusy(true);
        try {
            await api("/restart", { method: "POST" });
            setToast("Restart requested…");
            setTimeout(refresh, 2000);
        } catch (e) {
            setToast(`Restart error: ${e.message}`);
        } finally {
            setBusy(false);
        }
    }

    async function sendRcon() {
        if (!rconCmd.trim()) return;
        setBusy(true);
        try {
            const j = await api("/rcon", {
                method: "POST",
                body: JSON.stringify({ command: rconCmd }),
            });
            setToast(j.output || "Command sent");
        } catch (e) {
            setToast(`RCON error: ${e.message}`);
        } finally {
            setBusy(false);
            setRconCmd("");
        }
    }

    useEffect(() => {
        refresh();
        const id = setInterval(refresh, 5 * 60 * 1000);
        return () => clearInterval(id);
    }, []);

    return (
        <div className="page">
            <header className="header">
                <h1>ASA Server Control</h1>
                <p className="subtle">API: {API}</p>
            </header>

            {/* Status */}
            <section className="card">
                <div className="row between">
                    <div>
                        <div className="label">Status</div>
                        <div className="status-line">
                            {status.running ? (
                                <b className="ok">Running</b>
                            ) : (
                                <b className="bad">Stopped</b>
                            )}
                            {status.pid && <span className="muted"> (pid {status.pid})</span>}
                            {status.via && <span className="muted"> — via {status.via}</span>}
                        </div>
                    </div>
                    <div className="actions">
                        <button className="btn" onClick={refresh} disabled={busy}>
                            Refresh
                        </button>
                        {!status.running ? (
                            <button
                                className="btn success"
                                onClick={start}
                                disabled={busy}
                                title="Start"
                            >
                                Start
                            </button>
                        ) : (
                            <button
                                className="btn danger"
                                onClick={stop}
                                disabled={busy}
                                title="Stop"
                            >
                                Stop
                            </button>
                        )}
                        <button
                            className="btn primary"
                            onClick={restart}
                            disabled={busy || !status.running}
                            title="Restart"
                        >
                            Restart
                        </button>
                    </div>
                </div>
            </section>

            {/* Start Options */}
            <section className="card">
                <h2>Start Options</h2>
                <label className="field">
                    <span>Session Name</span>
                    <input
                        className="input"
                        value={sessionName}
                        onChange={(e) => setSessionName(e.target.value)}
                    />
                </label>
                <label className="field">
                    <span>Mods (comma-separated IDs)</span>
                    <input
                        className="input"
                        value={mods}
                        onChange={(e) => setMods(e.target.value)}
                    />
                </label>
                <label className="field">
                    <span>Server Password (optional)</span>
                    <input
                        className="input"
                        type="password"
                        value={serverPassword}
                        onChange={(e) => setServerPassword(e.target.value)}
                        placeholder="Leave blank for none"
                    />
                </label>
                <label className="field">
                    <span>Admin Password</span>
                    <input
                        className="input"
                        type="password"
                        value={adminPassword}
                        onChange={(e) => setAdminPassword(e.target.value)}
                    />
                </label>
                <label className="field">
                    <span>Max Players</span>
                    <input
                        className="input"
                        type="number"
                        min="1"
                        max="100"
                        value={maxPlayers}
                        onChange={(e) => setMaxPlayers(e.target.value)}
                    />
                </label>
                <label className="checkbox">
                    <input
                        type="checkbox"
                        checked={noBE}
                        onChange={(e) => setNoBE(e.target.checked)}
                    />
                    <span>Disable BattlEye</span>
                </label>
                <div className="actions">
                    <button className="btn success" onClick={start} disabled={busy}>
                        Start with Options
                    </button>
                </div>
            </section>

            {/* RCON */}
            <section className="card">
                <h2>RCON Quick Command</h2>
                <div className="row">
                    <input
                        className="input flex1"
                        placeholder="e.g. saveworld"
                        value={rconCmd}
                        onChange={(e) => setRconCmd(e.target.value)}
                    />
                    <button
                        className="btn dark"
                        onClick={sendRcon}
                        disabled={busy || !rconCmd.trim()}
                    >
                        Send
                    </button>
                </div>
                <p className="hint">
                    Requires <code>/rcon</code> endpoint and <code>RCONEnabled=True</code>{' '}
                    in your server config.
                </p>
            </section>

            {/* Toast */}
            <div
                className={`toast ${toast ? "show" : ""}`}
                role="status"
                aria-live="polite"
                onAnimationEnd={() => setTimeout(() => setToast(""), 2200)}
            >
                {toast}
            </div>
        </div>
    );
}
