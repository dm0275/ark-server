#requires -Version 5.1
<#
.SYNOPSIS
Controls the ASA frontend and backend dev servers.

.DESCRIPTION
Starts, stops, or reports on the background dev processes.  The script keeps
track of PIDs in a .run folder under the repo so it can avoid duplicate
launches and stop the correct processes later.

.PARAMETER Command
Action to perform: start (default), stop, status, or restart.

.PARAMETER RepoRoot
Repository root that contains backend/, frontend/, and scripts/.

.PARAMETER SkipInstall
Skip backend dependency installation when starting.
#>
param(
  [ValidateSet("start","stop","status","restart")]
  [string]$Command = "start",
  [string]$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path,
  [switch]$SkipInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$stateDir = Join-Path $RepoRoot ".run"
if (-not (Test-Path -LiteralPath $stateDir)) {
  New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}

$launcherNameMap = @{
  backend  = "backend-launcher"
  frontend = "frontend-launcher"
}

$primaryPidFiles = @{
  backend  = Join-Path $stateDir "backend-api.pid"
  frontend = Join-Path $stateDir "frontend-dev.pid"
  ark      = Join-Path $stateDir "ark-server.pid"
}

function Resolve-LauncherName {
  param([Parameter(Mandatory)][string]$Name)
  if ($launcherNameMap.ContainsKey($Name)) {
    return $launcherNameMap[$Name]
  }
  return $Name
}

function Get-PidFile {
  param([Parameter(Mandatory)][string]$Name)
  $resolved = Resolve-LauncherName -Name $Name
  return Join-Path $stateDir "$resolved.pid"
}

function Read-Pid {
  param([Parameter(Mandatory)][string]$Name)
  $file = Get-PidFile -Name $Name
  if (-not (Test-Path -LiteralPath $file)) {
    return $null
  }
  try {
    return [int](Get-Content -LiteralPath $file -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Write-Pid {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][int]$ProcessId
  )
  $file = Get-PidFile -Name $Name
  Set-Content -LiteralPath $file -Value $ProcessId -Encoding ascii
}

function Clear-Pid {
  param([Parameter(Mandatory)][string]$Name)
  $file = Get-PidFile -Name $Name
  if (Test-Path -LiteralPath $file) {
    Remove-Item -LiteralPath $file -Force
  }
}

function Test-ProcessAlive {
  param([Parameter(Mandatory)][int]$ProcessId)
  $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  return $proc -ne $null
}

function Ensure-Stopped {
  param([Parameter(Mandatory)][string]$Name)
  $storedPid = Read-Pid -Name $Name
  if (-not $storedPid) { return $false }

  if (Test-ProcessAlive -ProcessId $storedPid) {
    Write-Host "Stopping $Name (pid $storedPid)..."
    try {
      Stop-Process -Id $storedPid -Force -ErrorAction Stop
    } catch {
      Write-Warning "Failed to stop $Name (pid $storedPid): $($_.Exception.Message)"
    }
    Start-Sleep -Milliseconds 200
  }
  Clear-Pid -Name $Name
  return $true
}

function Read-PrimaryPid {
  param([Parameter(Mandatory)][string]$Name)
  if (-not $primaryPidFiles.ContainsKey($Name)) { return $null }
  $path = $primaryPidFiles[$Name]
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try {
    return [int](Get-Content -LiteralPath $path -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Test-PrimaryProcessAlive {
  param([Parameter(Mandatory)][string]$Name)
  $pid = Read-PrimaryPid -Name $Name
  if (-not $pid) { return $false }
  return Test-ProcessAlive -ProcessId $pid
}

function Stop-PrimaryProcess {
  param([Parameter(Mandatory)][string]$Name)
  $pid = Read-PrimaryPid -Name $Name
  if (-not $pid) { return $false }
  if (-not (Test-ProcessAlive -ProcessId $pid)) { return $false }

  Write-Host "Stopping $Name (primary pid $pid)..."
  try {
    Stop-Process -Id $pid -Force -ErrorAction Stop
  } catch {
    Write-Warning "Failed to stop $Name primary process (pid $pid): $($_.Exception.Message)"
    return $false
  }
  Start-Sleep -Milliseconds 200
  return $true
}

function Start-Backend {
  $name = "backend"
  $primaryPid = Read-PrimaryPid -Name $name
  if ($primaryPid -and (Test-ProcessAlive -ProcessId $primaryPid)) {
    Write-Host "Backend already running (pid $primaryPid)."
    return
  }
  $storedPid = Read-Pid -Name $name
  if ($storedPid -and (Test-ProcessAlive -ProcessId $storedPid)) {
    Write-Host "Backend already running (pid $storedPid)."
    return
  }
  Clear-Pid -Name $name

  $backendScript = Join-Path $RepoRoot "scripts\start-backend.ps1"
  $args = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $backendScript,
    "-RepoRoot", $RepoRoot,
    "-Reload"
  )
  if ($SkipInstall) { $args += "-SkipInstall" }

  Write-Host "Starting backend..."
  $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $args -WindowStyle Hidden -PassThru -WorkingDirectory $RepoRoot
  Write-Pid -Name $name -ProcessId $proc.Id
  Write-Host "Backend started (pid $($proc.Id))."
}

function Start-Frontend {
  $name = "frontend"
  $primaryPid = Read-PrimaryPid -Name $name
  if ($primaryPid -and (Test-ProcessAlive -ProcessId $primaryPid)) {
    Write-Host "Frontend already running (pid $primaryPid)."
    return
  }
  $storedPid = Read-Pid -Name $name
  if ($storedPid -and (Test-ProcessAlive -ProcessId $storedPid)) {
    Write-Host "Frontend already running (pid $storedPid)."
    return
  }
  Clear-Pid -Name $name

  $frontendDir = Join-Path $RepoRoot "frontend"
  Write-Host "Starting frontend (npm run dev)..."
  $proc = Start-Process -FilePath "npm.cmd" -ArgumentList @("run","start") -WorkingDirectory $frontendDir -WindowStyle Hidden -PassThru
  Write-Pid -Name $name -ProcessId $proc.Id
  Write-Host "Frontend started (pid $($proc.Id))."
}

function Show-Status {
  foreach ($name in @("backend","frontend")) {
    $primaryPid = Read-PrimaryPid -Name $name
    if ($primaryPid -and (Test-ProcessAlive -ProcessId $primaryPid)) {
      Write-Host ("{0,-10}: running (pid {1})" -f $name, $primaryPid)
      continue
    }

    $storedPid = Read-Pid -Name $name
    if ($storedPid -and (Test-ProcessAlive -ProcessId $storedPid)) {
      Write-Host ("{0,-10}: running (pid {1}) [launcher]" -f $name, $storedPid)
    } elseif ($storedPid) {
      Clear-Pid -Name $name
      Write-Host ("{0,-10}: not running (stale pid {1} removed)" -f $name, $storedPid)
    } else {
      Write-Host ("{0,-10}: not running" -f $name)
    }
  }
}

switch ($Command) {
  "start" {
    Start-Backend
    Start-Frontend
    break
  }
  "stop" {
    $stoppedBackend = Ensure-Stopped -Name "backend"
    $stoppedFrontend = Ensure-Stopped -Name "frontend"
    $primaryBackend = Stop-PrimaryProcess -Name "backend"
    $primaryFrontend = Stop-PrimaryProcess -Name "frontend"
    if (-not $stoppedBackend -and -not $stoppedFrontend -and -not $primaryBackend -and -not $primaryFrontend) {
      Write-Host "Nothing to stop."
    } else {
      Write-Host "Stop complete."
    }
    break
  }
  "status" {
    Show-Status
    break
  }
  "restart" {
    Ensure-Stopped -Name "backend" | Out-Null
    Ensure-Stopped -Name "frontend" | Out-Null
    Stop-PrimaryProcess -Name "backend" | Out-Null
    Stop-PrimaryProcess -Name "frontend" | Out-Null
    Start-Backend
    Start-Frontend
    break
  }
  default {
    throw "Unknown command: $Command"
  }
}
