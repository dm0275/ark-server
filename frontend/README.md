# ASA Control Frontend

A Vite + React UI that talks to the ASA backend API. It handles server start/stop, reporting status, and sending quick RCON commands.

## Environment Configuration

Create a `.env.local` (or any Vite-supported env file) in `frontend/` to wire the app to your backend:

```dotenv
# Base URL for the API (defaults to http://localhost:8000)
VITE_ASA_API_URL=http://192.168.1.40:8000

# API key that must match backend ASA_API_KEY
VITE_ASA_API_KEY=supersecret

# Optional: default server password to prefill in the UI (empty = none)
VITE_ASA_SERVER_PASSWORD=

# Optional: default admin password to prefill in the UI
VITE_ASA_ADMIN_PASSWORD=ChangeMeAdmin!
```

After setting the values, restart `npm run dev` so Vite picks them up. These env vars can also be supplied via your deployment platform.

## Getting Started

```bash
cd frontend
npm install
npm run dev
```

The dev server runs on `http://localhost:3000` by default. Update `VITE_ASA_API_URL` if the API lives elsewhere.
