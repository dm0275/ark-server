#requires -Version 5.1
<#
.SYNOPSIS
Starts the FastAPI backend server using uvicorn.

.DESCRIPTION
Activates the project's virtual environment (if present) or falls back to system Python,
installs dependencies if requested, and launches uvicorn pointing at src.server:app.

.PARAMETER RepoRoot
Root of the repository that contains the backend project. Defaults to script root/..

.PARAMETER Host
Host interface for uvicorn to bind. Defaults to 0.0.0.0.

.PARAMETER Port
Port for the backend server. Defaults to 8000.

.PARAMETER Reload
Enable uvicorn reload (good for development). Enabled by default.

.PARAMETER SkipInstall
Skip running pip install before starting the server.

.PARAMETER ExtraArgs
Additional arguments passed to uvicorn.
#>
param(
  [string]$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path,
  [string]$Host = "0.0.0.0",
  [int]$Port = 8000,
  [switch]$Reload,
  [switch]$SkipInstall,
  [string[]]$ExtraArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "Using repository root: $RepoRoot"
$backendDir = Join-Path $RepoRoot 'backend'
$venvDir = Join-Path $RepoRoot 'venv'
$requirements = Join-Path $backendDir 'requirements.txt'

function Resolve-Python {
  param(
    [string]$VenvDir
  )

  $candidate = Join-Path $VenvDir 'Scripts\python.exe'
  if (Test-Path -LiteralPath $candidate) {
    Write-Host "Using virtual environment python: $candidate"
    return $candidate
  }

  $python = Get-Command python.exe -ErrorAction SilentlyContinue
  if ($python) {
    Write-Host "Using python from PATH: $($python.Source)"
    return $python.Source
  }

  throw "Python executable not found. Install Python or create a virtual environment."
}

$pythonExe = Resolve-Python -VenvDir $venvDir

if (-not $SkipInstall -and (Test-Path -LiteralPath $requirements)) {
  Write-Host "Installing backend dependencies..."
  & $pythonExe -m pip install --upgrade pip
  if ($LASTEXITCODE -ne 0) {
    throw "pip upgrade failed (exit code $LASTEXITCODE)."
  }

  & $pythonExe -m pip install -r $requirements
  if ($LASTEXITCODE -ne 0) {
    throw "pip install failed (exit code $LASTEXITCODE)."
  }
} else {
  Write-Host "Skipping backend dependency installation."
}

$uvicornArgs = @(
  "-m", "uvicorn",
  "src.server:app",
  "--host", $Host,
  "--port", $Port
)

if ($Reload) {
  $uvicornArgs += "--reload"
}

if ($ExtraArgs) {
  $uvicornArgs += $ExtraArgs
}

Write-Host "Starting backend server..."
Push-Location $backendDir
try {
  & $pythonExe @uvicornArgs
} finally {
  Pop-Location
}
