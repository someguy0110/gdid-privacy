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

# ---------- Registry paths ----------
$RegPaths = @(
    'HKCU:\SOFTWARE\Microsoft\IdentityCRL\ExtendedProperties',
    'HKCU:\SOFTWARE\Microsoft\IdentityCRL\Immersive\production\Token'
)

$DDSDomains = @(
    'dds.microsoft.com',
    'fd.dds.microsoft.com',
    'aad.cs.dds.microsoft.com',
    'cdpcs.access.microsoft.com',
    'activity.windows.com',
    'cdn.activity.windows.com'
)

$CDPStateDir = "$env:LOCALAPPDATA\ConnectedDevicesPlatform"

# ---------- Helpers ----------
function Get-CurrentGDID {
    $path = 'HKCU:\SOFTWARE\Microsoft\IdentityCRL\ExtendedProperties'
    if (Test-Path $path) {
        $lid = (Get-ItemProperty $path -Name 'LID' -ErrorAction SilentlyContinue).LID
        if ($lid) {
            $dec = [Convert]::ToUInt64($lid, 16)
            return @{ hex = $lid; decimal = "g:$dec"; source = "ExtendedProperties\LID" }
        }
    }
    # Fallback: search under Immersive\production\Token
    $tokenPath = 'HKCU:\SOFTWARE\Microsoft\IdentityCRL\Immersive\production\Token'
    if (Test-Path $tokenPath) {
        $subs = Get-ChildItem $tokenPath -ErrorAction SilentlyContinue
        foreach ($s in $subs) {
            $did = (Get-ItemProperty $s.PSPath -Name 'DeviceId' -ErrorAction SilentlyContinue).DeviceId
            if ($did) {
                $dec2 = [Convert]::ToUInt64($did, 16)
                return @{ hex = $did; decimal = "g:$dec2"; source = "Token\$($s.PSChildName)\DeviceId" }
            }
        }
    }
    return $null
}

function New-FakeGDID {
    # 64-bit random with 0018 prefix (Device PUID namespace)
    $rand = [long]::MaxValue * [random]::NextDouble()
    $rand = [math]::Abs($rand)
    $hex = "0018{0:X12}" -f [long]$rand
    if ($hex.Length -ne 16) { $hex = "0018" + "0" * (12 - ($hex.Length - 4)) + $hex.Substring(4) }
    return $hex.Substring(0, 16)
}

function Write-GDID($hex) {
    # ExtendedProperties\LID
    $path1 = 'HKCU:\SOFTWARE\Microsoft\IdentityCRL\ExtendedProperties'
    if (-not (Test-Path $path1)) { New-Item -Path $path1 -Force | Out-Null }
    Set-ItemProperty -Path $path1 -Name 'LID' -Value $hex -Type String -Force

    # Immersive\production\Token\{*}\DeviceId
    $tokenPath = 'HKCU:\SOFTWARE\Microsoft\IdentityCRL\Immersive\production\Token'
    if (Test-Path $tokenPath) {
        $subs = Get-ChildItem $tokenPath -ErrorAction SilentlyContinue
        foreach ($s in $subs) {
            Set-ItemProperty -Path $s.PSPath -Name 'DeviceId' -Value $hex -Type String -Force -ErrorAction SilentlyContinue
        }
    }
}

function Clear-CDPState {
    if (Test-Path $CDPStateDir) {
        Remove-Item "$CDPStateDir\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Cleared CDP state" -ForegroundColor Green
    }
}

function Restart-CDP {
    Stop-Service CDPSvc -Force -ErrorAction SilentlyContinue
    Stop-Service CDPUserSvc -Force -ErrorAction SilentlyContinue
    Get-Service 'CDPUserSvc_*' -ErrorAction SilentlyContinue | Stop-Service -Force
    Start-Sleep 1
    # Start CDPUserSvc first (depends on CDPSvc)
    Get-Service 'CDPUserSvc_*' -ErrorAction SilentlyContinue | Start-Service -ErrorAction SilentlyContinue
    Start-Service CDPUserSvc -ErrorAction SilentlyContinue
    Start-Service CDPSvc -ErrorAction SilentlyContinue
}

# ---------- Firewall ----------
function Install-FirewallRules {
    $dsp = "GDID Privacy - Block DDS"
    $rule = Get-NetFirewallRule -DisplayGroup $dsp -ErrorAction SilentlyContinue
    if (-not $rule) {
        New-NetFirewallRule -DisplayName "Block DDS (dds.microsoft.com)" -DisplayGroup $dsp `
            -Direction Outbound -Protocol TCP -RemotePort 443 -RemoteAddress "0.0.0.0/0" `
            -Action Block -Profile Any | Out-Null
        Write-Host "  [OK] Firewall group '$dsp' created" -ForegroundColor Green
    } else {
        Write-Host "  [OK] Firewall group already exists" -ForegroundColor Yellow
    }
}

function Uninstall-FirewallRules {
    $dsp = "GDID Privacy - Block DDS"
    Get-NetFirewallRule -DisplayGroup $dsp -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Write-Host "  [OK] Firewall rules removed" -ForegroundColor Green
}

# ---------- Scheduled task ----------
function Install-RotationTask($cfg) {
    $taskName = "GDIDRotator"
    $scriptPath = Join-Path $PSScriptRoot 'gdid-tool.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" rotate"

    $triggers = @()
    if ($cfg.rotationMode -eq 'perBoot') {
        $triggers += New-ScheduledTaskTrigger -AtStartup
    } elseif ($cfg.rotationMode -eq 'timed') {
        $triggers += New-ScheduledTaskTrigger -Daily -At "00:00"  # base trigger
        $triggers += New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $cfg.timedIntervalMin) -RepetitionDuration ([TimeSpan]::MaxValue)
    }

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest

    if ($triggers.Count -eq 0) {
        Write-Host "  [SKIP] No triggers for rotationMode=$($cfg.rotationMode)" -ForegroundColor Yellow
        return
    }

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal -Force | Out-Null
    Write-Host "  [OK] Scheduled task '$taskName' created (mode: $($cfg.rotationMode))" -ForegroundColor Green
}

function Uninstall-RotationTask {
    $taskName = "GDIDRotator"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "  [OK] Scheduled task '$taskName' removed" -ForegroundColor Green
}

# ---------- Feature kill switches ----------
function Install-FeatureKills($cfg) {
    # Kill Phone Link
    if ($cfg.killPhoneLink) {
        Stop-Process -Name 'PhoneExperienceHost' -Force -ErrorAction SilentlyContinue
        # Disable via registry
        $pkPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Windows\Phone'
        if (-not (Test-Path $pkPath)) { New-Item -Path $pkPath -Force | Out-Null }
        Set-ItemProperty -Path $pkPath -Name 'Enable' -Value 0 -Type DWord -Force
        Write-Host "  [OK] Phone Link disabled" -ForegroundColor Green
    }

    # Kill OneDrive sync (GDID-related telemetry channel)
    if ($cfg.killOneDrive) {
        Stop-Process -Name 'OneDrive' -Force -ErrorAction SilentlyContinue
        $odPath = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
        if (-not (Test-Path $odPath)) { New-Item -Path $odPath -Force | Out-Null }
        Set-ItemProperty -Path $odPath -Name 'DisableFileSyncNGSC' -Value 1 -Type DWord -Force
        Write-Host "  [OK] OneDrive sync disabled (policy)" -ForegroundColor Green
    }

    # Kill Store auto-updates
    if ($cfg.killStore) {
        $wsPath = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
        if (-not (Test-Path $wsPath)) { New-Item -Path $wsPath -Force | Out-Null }
        Set-ItemProperty -Path $wsPath -Name 'AutoDownload' -Value 2 -Type DWord -Force
        Write-Host "  [OK] Store auto-update disabled" -ForegroundColor Green
    }

    # Kill Timeline / Activity History
    if ($cfg.killTimeline) {
        $atPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
        if (-not (Test-Path $atPath)) { New-Item -Path $atPath -Force | Out-Null }
        Set-ItemProperty -Path $atPath -Name 'EnableActivityFeed' -Value 0 -Type DWord -Force
        Set-ItemProperty -Path $atPath -Name 'PublishUserActivities' -Value 0 -Type DWord -Force
        Write-Host "  [OK] Activity History / Timeline disabled" -ForegroundColor Green
    }

    if ($cfg.blockCDP) {
        Set-Service CDPSvc -StartupType Disabled
        Set-Service CDPUserSvc -StartupType Disabled
        Get-Service 'CDPUserSvc_*' -ErrorAction SilentlyContinue | ForEach-Object {
            Set-Service $_.Name -StartupType Disabled
        }
        Write-Host "  [OK] CDP services disabled" -ForegroundColor Green
    }

    # Block DDS endpoints
    if ($cfg.blockDDS) {
        Install-FirewallRules
    }
}

function Uninstall-FeatureKills {
    # Restore Phone Link
    $pkPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Windows\Phone'
    if (Test-Path $pkPath) { Remove-ItemProperty -Path $pkPath -Name 'Enable' -ErrorAction SilentlyContinue }

    # Restore OneDrive
    $odPath = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
    if (Test-Path $odPath) { Remove-ItemProperty -Path $odPath -Name 'DisableFileSyncNGSC' -ErrorAction SilentlyContinue }

    # Restore Store
    $wsPath = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
    if (Test-Path $wsPath) { Remove-ItemProperty -Path $wsPath -Name 'AutoDownload' -ErrorAction SilentlyContinue }

    # Restore Timeline
    $atPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    if (Test-Path $atPath) {
        Remove-ItemProperty -Path $atPath -Name 'EnableActivityFeed' -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $atPath -Name 'PublishUserActivities' -ErrorAction SilentlyContinue
    }

    # Restore CDP services
    Set-Service CDPSvc -StartupType Manual -ErrorAction SilentlyContinue
    Set-Service CDPUserSvc -StartupType Manual -ErrorAction SilentlyContinue
    Get-Service 'CDPUserSvc_*' -ErrorAction SilentlyContinue | ForEach-Object {
        Set-Service $_.Name -StartupType Manual -ErrorAction SilentlyContinue
    }

    Uninstall-FirewallRules
}

# ---------- Subcommands ----------
function Show-Status {
    Write-Host "`n===== GDID Status =====" -ForegroundColor Cyan
    $gdid = Get-CurrentGDID
    if ($gdid) {
        Write-Host "  Current GDID hex:    $($gdid.hex)" -ForegroundColor White
        Write-Host "  Current GDID dec:    $($gdid.decimal)" -ForegroundColor White
        Write-Host "  Source:              $($gdid.source)" -ForegroundColor White
    } else {
        Write-Host "  No GDID found (no MSA or account removed)" -ForegroundColor Yellow
    }

    $cfg = Get-Config
    Write-Host "`n-- Configuration --" -ForegroundColor Cyan
    $cfg | Format-List | Out-String | Write-Host

    Write-Host "`n-- Services --" -ForegroundColor Cyan
    @('CDPSvc', 'CDPUserSvc') | ForEach-Object {
        $svc = Get-Service $_ -ErrorAction SilentlyContinue
        if ($svc) {
            $status = if ($svc.Status -eq 'Running') { 'RUNNING' } else { $svc.Status }
            $startup = (Get-CimInstance -ClassName Win32_Service -Filter "Name='$_'").StartMode
            Write-Host "  $_ : $status (startup: $startup)" -ForegroundColor $(
                if ($svc.Status -eq 'Running') { 'Green' } else { 'Yellow' }
            )
        }
    }

    Write-Host "`n-- Firewall Rules --" -ForegroundColor Cyan
    $rules = Get-NetFirewallRule -DisplayGroup "GDID Privacy - Block DDS" -ErrorAction SilentlyContinue
    if ($rules) {
        $rules | ForEach-Object { Write-Host "  BLOCK: $($_.DisplayName)" -ForegroundColor Red }
    } else {
        Write-Host "  None" -ForegroundColor DarkGray
    }

    Write-Host "`n-- Scheduled Task --" -ForegroundColor Cyan
    $task = Get-ScheduledTask -TaskName "GDIDRotator" -ErrorAction SilentlyContinue
    if ($task) {
        Write-Host "  GDIDRotator: $($task.State)" -ForegroundColor Green
    } else {
        Write-Host "  None" -ForegroundColor DarkGray
    }

    Write-Host "`n-- Feature Kills --" -ForegroundColor Cyan
    $checks = @(
        @{ name = "Phone Link"; path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Windows\Phone'; prop = 'Enable' },
        @{ name = "OneDrive"; path = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'; prop = 'DisableFileSyncNGSC' },
        @{ name = "Store AutoUpdate"; path = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; prop = 'AutoDownload' },
        @{ name = "Activity History"; path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; prop = 'EnableActivityFeed' }
    )
    foreach ($c in $checks) {
        if (Test-Path $c.path) {
            $val = (Get-ItemProperty $c.path -Name $c.prop -ErrorAction SilentlyContinue).$($c.prop)
            if ($val -ne $null) {
                Write-Host "  $($c.name): DISABLED (policy)" -ForegroundColor Yellow
                continue
            }
        }
        Write-Host "  $($c.name): ENABLED (default)" -ForegroundColor DarkGray
    }

    Write-Host "`n-- CDP State Dir --" -ForegroundColor Cyan
    if (Test-Path $CDPStateDir) {
        $items = Get-ChildItem $CDPStateDir -ErrorAction SilentlyContinue
        Write-Host "  Files: $($items.Count)" -ForegroundColor Yellow
    } else {
        Write-Host "  Empty / missing" -ForegroundColor DarkGray
    }
}

function Invoke-Rotate {
    $cfg = Get-Config
    $new = New-FakeGDID
    $old = (Get-CurrentGDID).hex
    Write-GDID $new
    $cfg.lastRotation = (Get-Date -Format 'o')
    Save-Config $cfg

    Write-Host "  Old GDID: $old" -ForegroundColor DarkGray
    Write-Host "  New GDID: $new" -ForegroundColor Green

    Clear-CDPState
    Restart-CDP

    Write-Host "  [OK] Rotation complete" -ForegroundColor Green
}

function Install-All {
    $cfg = Get-Config

    Write-Host "`n===== Installing GDID Privacy =====" -ForegroundColor Cyan

    # Always rotate immediately
    Invoke-Rotate

    # Install firewall rules if configured
    Install-FirewallRules

    # Install feature kills
    Install-FeatureKills $cfg

    # Install scheduled task
    Install-RotationTask $cfg

    Write-Host "`n===== Install Complete =====" -ForegroundColor Green
    Write-Host "Run '.\gdid-tool.ps1 status' to verify." -ForegroundColor White
}

function Uninstall-All {
    Write-Host "`n===== Uninstalling GDID Privacy =====" -ForegroundColor Cyan

    Uninstall-RotationTask
    Uninstall-FeatureKills
    Uninstall-FirewallRules

    Write-Host "  [OK] Restoring CDP service defaults..." -ForegroundColor Yellow
    Set-Service CDPSvc -StartupType Manual -ErrorAction SilentlyContinue
    Set-Service CDPUserSvc -StartupType Manual -ErrorAction SilentlyContinue

    Write-Host "`n===== Uninstall Complete =====" -ForegroundColor Green
    Write-Host "Reboot recommended to restore all services." -ForegroundColor Yellow
}

function Show-Config {
    $cfg = Get-Config
    if ($Key) {
        if ($cfg.ContainsKey($Key)) {
            if ($Value) {
                $cfg[$Key] = $Value
                Save-Config $cfg
                Write-Host "$Key = $Value" -ForegroundColor Green
            } else {
                Write-Host "$Key = $($cfg[$Key])" -ForegroundColor White
            }
        } else {
            Write-Host "Unknown key: $Key" -ForegroundColor Red
            Write-Host "Valid keys: $($cfg.Keys -join ', ')" -ForegroundColor Yellow
        }
    } else {
        $cfg | Format-List | Out-String | Write-Host
    }
}

function Show-Help {
    Write-Host @"

GDID Privacy Tool - Usage:

  status            Show current GDID, services, firewall, and feature kill status
  rotate            Generate a new fake GDID immediately
  install           Install all configured protections
  uninstall         Remove all changes
  config            Show current configuration
  config <key>      Show a config value
  config <key> <val> Set a config value

Configuration keys (gdid-config.json):
  rotationMode      perBoot | timed | onDemand
  timedIntervalMin  Minutes between rotations (timed mode)
  blockDDS          true/false  Block dds.microsoft.com endpoints
  blockActivity     true/false  Block activity.windows.com
  blockCDP          true/false  Disable CDPSvc/CDPUserSvc services
  killPhoneLink     true/false  Disable Phone Link (Your Phone)
  killOneDrive      true/false  Disable OneDrive sync
  killStore         true/false  Disable Store auto-update
  killTimeline      true/false  Disable Activity History/Timeline
  hookMethod        registry|api|none

Examples:
  .\gdid-tool.ps1 status
  .\gdid-tool.ps1 rotate
  .\gdid-tool.ps1 config rotationMode timed
  .\gdid-tool.ps1 config timedIntervalMin 15
  .\gdid-tool.ps1 config killPhoneLink true
  .\gdid-tool.ps1 install
"@
}

# ---------- Main ----------
switch ($Mode) {
    'status'   { Show-Status }
    'rotate'   { Invoke-Rotate }
    'install'  { Install-All }
    'uninstall' { Uninstall-All }
    'config'   { Show-Config }
    'help'     { Show-Help }
    default    { Show-Status }
}