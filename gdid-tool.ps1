#!/usr/bin/env pwsh
<#
.SYNOPSIS
    GDID Privacy Tool - Control Windows Global Device Identifier tracking
.DESCRIPTION
    View, rotate, spoof, or block the Windows GDID (Global Device Identifier).
    GDID is a 64-bit MSA Device PUID used by Microsoft to track device identity
    across the Connected Devices Platform, Delivery Optimization, and telemetry.

    Modes:
      status       - Show current GDID, service/endpoint state
      rotate       - Immediately generate a new fake GDID
      install      - Install rotation + firewall rules as configured
      uninstall    - Remove all changes, restore defaults
      config       - View or change configuration
.PARAMETER Mode
    Subcommand to run: status, rotate, install, uninstall, config
.PARAMETER Key
    Config key to get/set (used with config subcommand)
.PARAMETER Value
    Config value to set (used with config subcommand)
.EXAMPLE
    .\gdid-tool.ps1 status
    .\gdid-tool.ps1 rotate
    .\gdid-tool.ps1 config rotationMode perBoot
    .\gdid-tool.ps1 install
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'rotate', 'install', 'uninstall', 'config', 'help')]
    [string]$Mode = 'status',

    [Parameter(Position = 1)]
    [string]$Key,

    [Parameter(Position = 2)]
    [string]$Value
)

#Requires -RunAsAdministrator

# ---------- Configuration ----------
$ConfigPath = Join-Path $PSScriptRoot 'gdid-config.json'

$DefaultConfig = @{
    rotationMode      = 'perBoot'    # perBoot | timed | onDemand
    timedIntervalMin  = 30
    blockDDS          = $true
    blockActivity     = $true
    blockCDP          = $false
    killPhoneLink     = $false
    killOneDrive      = $false
    killStore         = $false
    killTimeline      = $false
    hookMethod        = 'registry'   # registry | api | none
    lastRotation      = $null
}

function Get-Config {
    if (Test-Path $ConfigPath) {
        $c = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        $merged = $DefaultConfig.Clone()
        foreach ($k in $merged.Keys) {
            if ($c.$k -ne $null) { $merged[$k] = $c.$k }
        }
        return $merged
    }
    return $DefaultConfig.Clone()
}

function Save-Config($cfg) {
    $cfg | ConvertTo-Json | Set-Content $ConfigPath -Force
}

//... rest of script omitted for brevity, 20 functions total ...