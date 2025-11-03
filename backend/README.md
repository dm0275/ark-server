## Backend Configuration

The API reads configuration from environment variables and automatically loads
`.env` files located in `backend/` before it starts. Two files are
checked, if they exist:

- `backend/.env`
- `backend/.env.local`

Any variables defined there are available to the app. Common settings include:

```env
ASA_API_KEY=supersecret
ASA_WORKING_DIR=C:\arkascendedserver\ShooterGame\Binaries\Win64
ASA_ALLOWED_ORIGINS=http://localhost:3000
ASA_ALLOW_ALL_ORIGINS=false
ASA_LOG_DIR=C:\ark-server-logs
ASA_LOG_LEVEL=INFO
```

Environment variables still take precedence over values in the files (for
example anything injected by your service manager). Update `backend/requirements.txt`
and reinstall dependencies if you add new packages.
