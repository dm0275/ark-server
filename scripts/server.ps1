#requires -Version 5.1
param(
# Top-level command
  [Parameter(Mandatory=$true, Position=0)]
  [ValidateSet('setup','start','update','prefetch')]
  [string]$Command,

# Shared
  [string]$WorkingDir = "C:\arkascendedserver\ShooterGame\Binaries\Win64",
  [switch]$BootstrapIfMissing,
  [switch]$NoFirewall,
  [string]$Branch = "",
  [string]$BetaPassword = "",
  [switch]$SkipModPrefetch,
  [int]$TimeoutMinutes = 20,

# Server runtime settings
  [string]$Map = "TheIsland_WP",
  [string]$SessionName = "MyASAServer",
  [int]$MaxPlayers = 16,
  [int]$GamePort = 7777,
  [int]$QueryPort = 27015,
  [Nullable[int]]$RCONPort = 27020,
  [string]$ServerPassword = "",
  [string]$ServerAdminPassword = "",
  [switch]$NoBattlEye = $true,
  [string[]]$Mods = @("929578", "953154", "934231", "1061361"),
  [string[]]$ExtraArgs = @("-server","-log")
)

# =====================[ Helpers ]=====================

function Assert-Admin {
  $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) { throw "This action requires an elevated PowerShell (Run as Administrator)." }
}

function Ensure-Folder {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Get-ChocolateyExe {
  $defaultPath = 'C:\ProgramData\chocolatey\bin\choco.exe'
  if (Test-Path -LiteralPath $defaultPath) { return $defaultPath }

  $command = Get-Command choco.exe -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }

  throw "Chocolatey (choco.exe) is required but was not found. Install Chocolatey from https://chocolatey.org/install and re-run this script."
}

function Get-SteamCmdPath {
  $command = Get-Command steamcmd.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($command) { return $command.Source }

  $chocoDefault = Join-Path 'C:\ProgramData\chocolatey\lib\steamcmd\tools\steamcmd' 'steamcmd.exe'
  if (Test-Path -LiteralPath $chocoDefault) { return $chocoDefault }

  return $null
}

function Get-RootFromWorkingDir {
  param([Parameter(Mandatory=$true)][string]$WorkingDir)

  # Avoid Resolve-Path if it doesn't exist yet (fresh machine).
  $wd = $WorkingDir
  if (Test-Path -LiteralPath $WorkingDir) {
    try { $wd = (Resolve-Path -LiteralPath $WorkingDir -ErrorAction Stop).Path } catch { $wd = $WorkingDir }
  }

  # Walk up the tree without "if-as-expression" (PS5-safe).
  $lvl1 = Split-Path -Path $wd -Parent           # ...\Binaries
  $lvl2 = $null; if ($lvl1) { $lvl2 = Split-Path -Path $lvl1 -Parent }   # ...\ShooterGame
  $lvl3 = $null; if ($lvl2) { $lvl3 = Split-Path -Path $lvl2 -Parent }   # root (expected)

  $root = $lvl3
  if (-not $root) { $root = $lvl2 }
  if (-not $root) { $root = $lvl1 }
  if (-not $root) { $root = Split-Path -Path $wd -Parent }
  if (-not $root) { $root = (Get-Location).Path }
  return $root
}

function Test-VCppRedistInstalled {
  param()
  $keys = @(
    'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
  )
  foreach ($k in $keys) {
    try {
      $v = Get-ItemProperty -Path $k -ErrorAction Stop
      if ($v.Installed -eq 1 -and $v.Major -ge 14) { return $true }
    } catch {}
  }
  return $false
}

function Install-VCppRedist {
  Write-Host "Checking Microsoft Visual C++ 2015-2022 Redistributable (x64)..."

  if (Test-VCppRedistInstalled) { Write-Host "VC++ Redist already installed."; return }

  $chocoPath = Get-ChocolateyExe
  Write-Host "Installing VC++ Redist via Chocolatey ($chocoPath)..."
  & $chocoPath install vcredist140 -y --no-progress
  if ($LASTEXITCODE -ne 0) {
    throw "Chocolatey failed to install vcredist140 (exit code $LASTEXITCODE)."
  }
  if (-not (Test-VCppRedistInstalled)) {
    throw "Chocolatey completed, but the Microsoft Visual C++ 2015-2022 Redistributable (x64) is still not detected."
  }
  Write-Host "VC++ Redist installed via Chocolatey."
}

function Ensure-SteamCMD {
  param([Parameter(Mandatory)][string]$BaseDir)
  Assert-Admin

  $existingSteamCmd = Get-SteamCmdPath
  if ($existingSteamCmd) {
    Write-Host "SteamCMD already available at $existingSteamCmd"
    return $existingSteamCmd
  }

  $chocoPath = Get-ChocolateyExe
  Write-Host "Installing SteamCMD via Chocolatey ($chocoPath)..."
  & $chocoPath install steamcmd -y --no-progress | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Chocolatey failed to install steamcmd (exit code $LASTEXITCODE)."
  }

  $steamCmdExe = Get-SteamCmdPath
  if (-not $steamCmdExe) {
    throw "SteamCMD installation via Chocolatey completed but steamcmd.exe was not found."
  }

  Write-Host "SteamCMD installed at $steamCmdExe"
  return $steamCmdExe
}

function Ensure-ASAServerFiles {
  param(
    [Parameter(Mandatory)][string]$BaseDir,
    [Parameter(Mandatory)][string]$SteamCmdExe,
    [string]$Branch = "",
    [string]$BetaPassword = ""
  )
  Assert-Admin

  $appId      = "2430930"
  $installDir = $BaseDir

  Ensure-Folder $installDir

  $cmdArgs = @(
    "+force_install_dir", $installDir,
    "+login", "anonymous",
    "+app_update", $appId
  )

  if ($Branch -and $Branch.Trim()) {
    $cmdArgs += "-beta"
    $cmdArgs += $Branch
    if ($BetaPassword -and $BetaPassword.Trim()) {
      $cmdArgs += "-betapassword"
      $cmdArgs += $BetaPassword
    }
    $cmdArgs += "validate"
  } else {
    $cmdArgs += "validate"
  }

  $cmdArgs += "+quit"

  $logCmd = $cmdArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
  Write-Host "Syncing ASA server files to $installDir (first run may take a while)..."
  Write-Host "SteamCMD command: $SteamCmdExe $($logCmd -join ' ')"

  & $SteamCmdExe @cmdArgs
  if ($LASTEXITCODE -ne 0) {
    throw "SteamCMD failed to install/update ASA server (exit $LASTEXITCODE)."
  }
  Write-Host "ASA server files are present."
}

function Ensure-FirewallRules {
  param([switch]$SkipFirewall)

  if ($SkipFirewall) { Write-Host "Skipping firewall configuration per -NoFirewall."; return }
  Assert-Admin

  $rules = @(
    @{ Name="ASA_UDP_7777";  Protocol="UDP"; Port=7777 },
    @{ Name="ASA_UDP_7778";  Protocol="UDP"; Port=7778 },
    @{ Name="ASA_UDP_27015"; Protocol="UDP"; Port=27015 },
    @{ Name="ASA_TCP_27020"; Protocol="TCP"; Port=27020 }
  )

  foreach ($r in $rules) {
    $Name=$r.Name; $Protocol=$r.Protocol; $Port=$r.Port
    $existing = Get-NetFirewallRule -DisplayName $Name -ErrorAction SilentlyContinue
    if (-not $existing) {
      New-NetFirewallRule -DisplayName $Name -Direction Inbound -Action Allow -Protocol $Protocol -LocalPort $Port | Out-Null
      Write-Host ("Created firewall rule: {0} ({1} {2})" -f $Name, $Protocol, $Port)
    } else {
      Write-Host ("Firewall rule already exists: {0}" -f $Name)
    }
  }
}

function Build-ServerArgs {
  param(
    [string]$Map,
    [string]$SessionName,
    [int]$GamePort,
    [int]$QueryPort,
    [int]$MaxPlayers,
    [string]$ServerPassword,
    [string]$ServerAdminPassword,
    [Nullable[int]]$RCONPort,
    [switch]$NoBattlEye,
    [string[]]$Mods,
    [string[]]$ExtraArgs
  )

  $urlParts = @()
  $urlParts += "$Map"
  $urlParts += "?SessionName=$([uri]::EscapeDataString($SessionName))"
  $urlParts += "?Port=$GamePort"
  $urlParts += "?QueryPort=$QueryPort"
  $urlParts += "?MaxPlayers=$MaxPlayers"
  if ($ServerPassword)      { $urlParts += "?ServerPassword=$ServerPassword" }
  if ($ServerAdminPassword) { $urlParts += "?ServerAdminPassword=$ServerAdminPassword" }
  if ($null -ne $RCONPort)  { $urlParts += "?RCONPort=$RCONPort" }

  $args = @(($urlParts -join "") + " listen")

  if ($Mods -and $Mods.Count -gt 0) {
    $modList = ($Mods -join ",")
    $args += "-mods=$modList"
    Write-Host "Using ASA mods: $modList"
  }

  if ($NoBattlEye) { $args += "-NoBattlEye" }

  if ($ExtraArgs -and $ExtraArgs.Count -gt 0) { $args += $ExtraArgs }

  return ,$args
}

function Bootstrap-IfNeeded {
  param(
    [Parameter(Mandatory)][string]$WorkingDir,
    [switch]$NoFirewall,
    [string]$Branch = "",
    [string]$BetaPassword = ""
  )
  $baseDir = Get-RootFromWorkingDir -WorkingDir $WorkingDir
  Ensure-Folder $baseDir

  Install-VCppRedist
  $steamCmd = Ensure-SteamCMD -BaseDir $baseDir
  Ensure-ASAServerFiles -BaseDir $baseDir -SteamCmdExe $steamCmd -Branch $Branch -BetaPassword $BetaPassword
  Ensure-FirewallRules -SkipFirewall:$NoFirewall

  Write-Host "Bootstrap complete."
}

function Start-ASAServer {
  param(
    [Parameter(Mandatory)][string]$WorkingDir,
    [string]$Map,
    [string]$SessionName,
    [int]$MaxPlayers,
    [int]$GamePort,
    [int]$QueryPort,
    [Nullable[int]]$RCONPort,
    [string]$ServerPassword,
    [string]$ServerAdminPassword,
    [switch]$NoBattlEye,
    [string[]]$Mods,
    [string[]]$ExtraArgs
  )

  $exe = Join-Path $WorkingDir "ArkAscendedServer.exe"
  if (-not (Test-Path -LiteralPath $exe)) {
    throw "Server binary not found at $exe"
  }

  $args = Build-ServerArgs -Map $Map -SessionName $SessionName -GamePort $GamePort -QueryPort $QueryPort -MaxPlayers $MaxPlayers `
    -ServerPassword $ServerPassword -ServerAdminPassword $ServerAdminPassword -RCONPort $RCONPort `
    -NoBattlEye:$NoBattlEye -Mods $Mods -ExtraArgs $ExtraArgs

  Write-Host "Launching ASA server..."
  Write-Host "Path: $exe"
  Write-Host "Args: $($args -join ' ')"
  Start-Process -FilePath $exe -ArgumentList $args -NoNewWindow -WorkingDirectory $WorkingDir
}

function Prefetch-ASAMods {
  param(
    [Parameter(Mandatory)][string]$WorkingDir,
    [string]$Map,
    [string]$SessionName,
    [int]$MaxPlayers,
    [int]$GamePort,
    [int]$QueryPort,
    [Nullable[int]]$RCONPort,
    [string]$ServerPassword,
    [string]$ServerAdminPassword,
    [switch]$NoBattlEye,
    [string[]]$Mods,
    [string[]]$ExtraArgs,
    [int]$TimeoutMinutes
  )

  if (-not ($Mods) -or $Mods.Count -eq 0) {
    Write-Host "No mods specified; skipping prefetch."
    return
  }

  $exe = Join-Path $WorkingDir "ArkAscendedServer.exe"
  if (-not (Test-Path -LiteralPath $exe)) {
    throw "ArkAscendedServer.exe not found at: $exe"
  }

  $prefetchExtras = @("-server","-NoCrashDialog")
  if ($ExtraArgs) { $prefetchExtras += $ExtraArgs }

  $args = Build-ServerArgs -Map $Map -SessionName $SessionName -GamePort $GamePort -QueryPort $QueryPort -MaxPlayers $MaxPlayers `
    -ServerPassword $ServerPassword -ServerAdminPassword $ServerAdminPassword -RCONPort $RCONPort `
    -NoBattlEye:$NoBattlEye -Mods $Mods -ExtraArgs $prefetchExtras

  Write-Host "Starting temporary ASA server instance to prefetch mods..."
  $proc = Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $WorkingDir -PassThru

  $timeout = (Get-Date).AddMinutes($TimeoutMinutes)
  $logDir = Join-Path $WorkingDir "..\..\Saved\Logs"
  Write-Host "Monitoring logs in: $logDir"

  $modsDownloaded = $false
  try {
    do {
      Start-Sleep -Seconds 10
      $logFiles = Get-ChildItem -Path $logDir -Filter "*.log" -ErrorAction SilentlyContinue
      foreach ($log in $logFiles) {
        $complete = Get-Content $log.FullName -ErrorAction SilentlyContinue | Select-String "Mod download complete"
        if ($complete) {
          $modsDownloaded = $true
          break
        }
      }
    } until ($modsDownloaded -or (Get-Date) -gt $timeout)

    if ($modsDownloaded) {
      Write-Host "Mods downloaded successfully."
    } else {
      Write-Warning "Timeout reached ($TimeoutMinutes minutes). Mods may still be downloading."
    }
  } finally {
    if ($proc -and -not $proc.HasExited) {
      Write-Host "Stopping temporary server instance..."
      Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
  }
}

# =====================[ Command Dispatch ]=====================

switch ($Command) {
  'setup' {
    try {
      Bootstrap-IfNeeded -WorkingDir $WorkingDir -NoFirewall:$NoFirewall -Branch $Branch -BetaPassword $BetaPassword
      if (-not $SkipModPrefetch -and $Mods -and $Mods.Count -gt 0) {
        try {
          Prefetch-ASAMods -WorkingDir $WorkingDir -Map $Map -SessionName $SessionName -MaxPlayers $MaxPlayers `
            -GamePort $GamePort -QueryPort $QueryPort -RCONPort $RCONPort -ServerPassword $ServerPassword `
            -ServerAdminPassword $ServerAdminPassword -NoBattlEye:$NoBattlEye -Mods $Mods -ExtraArgs $ExtraArgs `
            -TimeoutMinutes $TimeoutMinutes
        } catch {
          Write-Warning "Mod prefetch failed: $($_.Exception.Message)"
        }
      }
    } catch { Write-Error $_; exit 1 }
    break
  }

  'start' {
    if ($BootstrapIfMissing) {
      try {
        Bootstrap-IfNeeded -WorkingDir $WorkingDir -NoFirewall:$NoFirewall -Branch $Branch -BetaPassword $BetaPassword
        if (-not $SkipModPrefetch -and $Mods -and $Mods.Count -gt 0) {
          try {
            Prefetch-ASAMods -WorkingDir $WorkingDir -Map $Map -SessionName $SessionName -MaxPlayers $MaxPlayers `
              -GamePort $GamePort -QueryPort $QueryPort -RCONPort $RCONPort -ServerPassword $ServerPassword `
              -ServerAdminPassword $ServerAdminPassword -NoBattlEye:$NoBattlEye -Mods $Mods -ExtraArgs $ExtraArgs `
              -TimeoutMinutes $TimeoutMinutes
          } catch {
            Write-Warning "Mod prefetch failed: $($_.Exception.Message)"
          }
        }
      }
      catch { Write-Error $_; exit 1 }
    }
    try {
      Start-ASAServer -WorkingDir $WorkingDir -Map $Map -SessionName $SessionName -MaxPlayers $MaxPlayers `
        -GamePort $GamePort -QueryPort $QueryPort -RCONPort $RCONPort -ServerPassword $ServerPassword -ServerAdminPassword $ServerAdminPassword `
        -NoBattlEye:$NoBattlEye -Mods $Mods -ExtraArgs $ExtraArgs
    } catch { Write-Error $_; exit 1 }
    break
  }

  'update' {
    if ($BootstrapIfMissing) {
      try { Bootstrap-IfNeeded -WorkingDir $WorkingDir -NoFirewall:$NoFirewall -Branch $Branch -BetaPassword $BetaPassword }
      catch { Write-Error $_; exit 1 }
    }
    try {
      $baseDir = Get-RootFromWorkingDir -WorkingDir $WorkingDir
      $steam   = Ensure-SteamCMD -BaseDir $baseDir
      & $steam "+force_install_dir `"$baseDir`" +login anonymous +app_update 2430930 validate +quit"
    } catch { Write-Error $_; exit 1 }
    break
  }

  'prefetch' {
    if ($BootstrapIfMissing) {
      try { Bootstrap-IfNeeded -WorkingDir $WorkingDir -NoFirewall:$NoFirewall -Branch $Branch -BetaPassword $BetaPassword }
      catch { Write-Error $_; exit 1 }
    }
    try {
      Prefetch-ASAMods -WorkingDir $WorkingDir -Map $Map -SessionName $SessionName -MaxPlayers $MaxPlayers `
        -GamePort $GamePort -QueryPort $QueryPort -RCONPort $RCONPort -ServerPassword $ServerPassword `
        -ServerAdminPassword $ServerAdminPassword -NoBattlEye:$NoBattlEye -Mods $Mods -ExtraArgs $ExtraArgs `
        -TimeoutMinutes $TimeoutMinutes
    } catch {
      Write-Error $_; exit 1
    }
    Write-Host "Prefetch command complete."
    break
  }

  default {
    Write-Error "Unknown command '$Command'. Use: setup | start | update | prefetch"
    exit 1
  }
}
