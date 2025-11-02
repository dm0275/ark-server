#requires -Version 5.1
<#
.SYNOPSIS
Creates or updates Windows Firewall inbound rules for the dev environment.

.DESCRIPTION
Ensures inbound ports for the frontend (default 3000) and optionally the backend are open.

.PARAMETER FrontendPort
TCP port to allow for the frontend. Defaults to 3000.

.PARAMETER BackendPort
Optional TCP port to allow for the backend API.
#>
param(
  [int]$FrontendPort = 3000,
  [Nullable[int]]$BackendPort = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Admin {
  $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This script must be run from an elevated PowerShell session (Run as Administrator)."
  }
}

function Ensure-PortRule {
  param(
    [Parameter(Mandatory)][string]$RuleName,
    [Parameter(Mandatory)][int]$Port
  )

  $existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
  if ($existing) {
    Write-Host "Firewall rule '$RuleName' already exists; ensuring port details..."
    Set-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Action Allow -Protocol TCP | Out-Null
    Set-NetFirewallPortFilter -AssociatedNetFirewallRule $existing -Protocol TCP -LocalPort $Port | Out-Null
  } else {
    Write-Host "Creating firewall rule '$RuleName' for TCP port $Port ..."
    New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port | Out-Null
  }
}

Assert-Admin

Ensure-PortRule -RuleName "ArkServer Frontend ($FrontendPort)" -Port $FrontendPort

if ($BackendPort) {
  Ensure-PortRule -RuleName "ArkServer Backend ($BackendPort)" -Port $BackendPort
}

Write-Host "Firewall configuration complete."
