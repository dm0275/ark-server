#requires -Version 5.1
<#
.SYNOPSIS
Installs Python and Node.js via Chocolatey and bootstraps local dependencies.

.DESCRIPTION
Ensures Chocolatey is available, installs/upgrades the requested Python and Node.js packages,
and then runs backend/frontend dependency installs if their folders are present.

.PARAMETER RepoRoot
Root of the repository that contains backend/ and frontend/ folders. Defaults to the project root.

.PARAMETER PythonPackage
Chocolatey package id used for Python. Defaults to "python".

.PARAMETER NodePackage
Chocolatey package id used for Node.js. Defaults to "nodejs-lts".

.PARAMETER SkipBackendInstall
Skip running pip install for the backend requirements.

.PARAMETER SkipFrontendInstall
Skip running npm install for the frontend packages.
#>
param(
  [string]$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path,
  [string]$PythonPackage = "python",
  [string]$NodePackage = "nodejs-lts",
  [switch]$SkipBackendInstall,
  [switch]$SkipFrontendInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Admin {
  $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This script must be run from an elevated PowerShell session (Run as Administrator)."
  }
}

function Get-ChocolateyExe {
  $defaultPath = 'C:\ProgramData\chocolatey\bin\choco.exe'
  if (Test-Path -LiteralPath $defaultPath) {
    return $defaultPath
  }

  $command = Get-Command choco.exe -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  throw "Chocolatey (choco.exe) was not found. Install Chocolatey from https://chocolatey.org/install and re-run this script."
}

function Install-ChocoPackage {
  param(
    [Parameter(Mandatory)][string]$ChocoExe,
    [Parameter(Mandatory)][string]$PackageId
  )

  Write-Host "Ensuring Chocolatey package '$PackageId' is installed..."
  $installed = & $ChocoExe list --local-only --exact $PackageId --limit-output | Select-String "^$PackageId\|" -ErrorAction SilentlyContinue

  if ($installed) {
    Write-Host "'$PackageId' already installed; upgrading to latest..."
    & $ChocoExe upgrade $PackageId -y --no-progress | Out-Null
  } else {
    Write-Host "Installing '$PackageId'..."
    & $ChocoExe install $PackageId -y --no-progress | Out-Null
  }

  if ($LASTEXITCODE -ne 0) {
    throw "Chocolatey failed to install or upgrade '$PackageId' (exit code $LASTEXITCODE)."
  }

  Write-Host "'$PackageId' installation complete."
}

function Get-CommandPath {
  param(
    [Parameter(Mandatory)][string]$CommandName
  )

  $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
  return if ($cmd) { $cmd.Source } else { $null }
}

Assert-Admin

Write-Host "Using repository root: $RepoRoot"
$choco = Get-ChocolateyExe

Install-ChocoPackage -ChocoExe $choco -PackageId $PythonPackage
$pythonExe = Get-CommandPath -CommandName "python.exe"
if (-not $pythonExe) {
  throw "Python executable not found on PATH after Chocolatey install."
}
Write-Host "Python executable: $pythonExe"

Install-ChocoPackage -ChocoExe $choco -PackageId $NodePackage
$npmExe = Get-CommandPath -CommandName "npm.cmd"
if (-not $npmExe) {
  throw "npm command not found on PATH after Chocolatey install."
}
Write-Host "npm executable: $npmExe"

$backendRequirements = Join-Path $RepoRoot 'backend\requirements.txt'
if (-not $SkipBackendInstall -and (Test-Path -LiteralPath $backendRequirements)) {
  Write-Host "Installing backend Python dependencies from $backendRequirements ..."
  & $pythonExe -m pip install --upgrade pip
  if ($LASTEXITCODE -ne 0) {
    throw "pip upgrade failed (exit code $LASTEXITCODE)."
  }

  & $pythonExe -m pip install -r $backendRequirements
  if ($LASTEXITCODE -ne 0) {
    throw "pip install of backend requirements failed (exit code $LASTEXITCODE)."
  }
} else {
  Write-Host "Skipping backend dependency install."
}

$frontendDir = Join-Path $RepoRoot 'frontend'
$frontendPackageJson = Join-Path $frontendDir 'package.json'
if (-not $SkipFrontendInstall -and (Test-Path -LiteralPath $frontendPackageJson)) {
  Write-Host "Installing frontend Node.js dependencies in $frontendDir ..."
  Push-Location $frontendDir
  try {
    & $npmExe install
    if ($LASTEXITCODE -ne 0) {
      throw "npm install failed (exit code $LASTEXITCODE)."
    }
  } finally {
    Pop-Location
  }
} else {
  Write-Host "Skipping frontend dependency install."
}

Write-Host "Environment setup complete."
