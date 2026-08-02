# GDID Privacy Tool v2 Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a compatibility-minded v2 hardening release that keeps the current CLI intact while making GDID masking claims truthful, removing unsupported hook mode from the supported surface, hardening config/state handling, and adding Windows validation gates.

**Architecture:** Keep `gdid-tool.ps1` as the main entrypoint, but carve its responsibilities into explicit helper regions for config migration, protected state, runtime state, scheduled tasks, verification, and output. Add a Windows-first validation harness under `tests/` and a GitHub Actions workflow so behavior changes are gated by parser, analyzer, and smoke checks before release.

**Tech Stack:** PowerShell 5.1+, optional PowerShell 7, Windows Scheduled Tasks, Windows registry/service management, GitHub Actions, PSScriptAnalyzer

---

## File Structure

### Existing Files To Modify

- `gdid-tool.ps1`
  - Main script entrypoint.
  - Add strict config validation, state/runtime separation, scheduled-task redesign, truthful status wording, and safer install/uninstall verification.
- `gdid-config.json`
  - Replace the legacy mixed-purpose config with the v2 schema.
- `README.md`
  - Rewrite product positioning, command semantics, and limits.
- `build-exe.ps1`
  - Gate EXE builds behind the Windows validation runner and stop assuming always-elevated usage.
- `gdid-tool.bat`
  - Keep launcher behavior aligned with the new non-elevated default status/help flow and elevation only for mutating install/uninstall operations.

### New Files To Create

- `.github/workflows/powershell-validation.yml`
  - Windows CI for parsing, linting, smoke tests, and release-package validation.
- `PSScriptAnalyzerSettings.psd1`
  - Shared analyzer policy for both Windows PowerShell and PowerShell 7.
- `tests/Parse-AllPowerShell.ps1`
  - Parse every `.ps1` file and fail on syntax errors.
- `tests/Run-AllChecks.ps1`
  - Master validation runner used locally and by CI.
- `tests/Validate-GDIDTool.ps1`
  - Package/config/help/status validation script.
- `TESTING.md`
  - Maintainer instructions for the validation workflow.
- `docs/MIGRATION-v2.md`
  - Upgrade notes for users moving from v1 behavior.
- `docs/RELEASE-v2.md`
  - Release notes for the hardening update.

### Optional Cleanup Targets

- `gdid-hook-dll/README.md`
  - Mark unsupported in the interim if the directory is not deleted in the same release.
- `gdid-hook-dll/*`
  - Remove or isolate after config/docs stop advertising `api` mode.

---

### Task 1: Add Windows Validation Gates

**Files:**
- Create: `.github/workflows/powershell-validation.yml`
- Create: `PSScriptAnalyzerSettings.psd1`
- Create: `tests/Parse-AllPowerShell.ps1`
- Create: `tests/Run-AllChecks.ps1`
- Create: `tests/Validate-GDIDTool.ps1`
- Create: `TESTING.md`
- Modify: `build-exe.ps1`

- [ ] **Step 1: Write the failing parser worker**

```powershell
# tests/Parse-AllPowerShell.ps1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Root
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$files = Get-ChildItem -Path $Root -Recurse -File -Include *.ps1 |
    Where-Object { $_.FullName -notmatch '[\\/](\.git|bin|obj)[\\/]' }

$failed = $false
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$errors
    )

    if ($errors.Count -gt 0) {
        $failed = $true
        Write-Host "[FAIL] $($file.FullName)" -ForegroundColor Red
        foreach ($errorRecord in $errors) {
            Write-Host "  $($errorRecord.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "[PASS] $($file.FullName)" -ForegroundColor Green
    }
}

if ($failed) {
    exit 1
}
```

- [ ] **Step 2: Run the parser worker to verify the baseline**

Run:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Parse-AllPowerShell.ps1 -Root .
```

Expected:

```text
[PASS] ...\gdid-tool.ps1
[PASS] ...\build-exe.ps1
...
```

- [ ] **Step 3: Write the validation runner and package validator**

```powershell
# tests/Run-AllChecks.ps1
[CmdletBinding()]
param(
    [switch]$IncludeStatus
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$main = Join-Path $root 'gdid-tool.ps1'
$parseWorker = Join-Path $PSScriptRoot 'Parse-AllPowerShell.ps1'
$validator = Join-Path $PSScriptRoot 'Validate-GDIDTool.ps1'

$common = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass')

& powershell.exe @common -File $parseWorker -Root $root
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Invoke-ScriptAnalyzer -Path $root -Recurse -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& powershell.exe @common -File $validator
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& powershell.exe @common -File $main help
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

& powershell.exe @common -File $main config
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($IncludeStatus) {
    & powershell.exe @common -File $main status
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
```

```powershell
# tests/Validate-GDIDTool.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $root 'gdid-config.json'

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Missing config file: $configPath"
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
foreach ($required in 'schemaVersion','rotationMode','blockCDP','blockHosts','hookMethod') {
    if (-not ($config.PSObject.Properties.Name -contains $required)) {
        throw "Config is missing required key '$required'."
    }
}

if ($config.rotationMode -notin @('onDemand','timed','perLogon')) {
    throw "rotationMode must be onDemand, timed, or perLogon."
}

if ($config.hookMethod -notin @('registry','none')) {
    throw "hookMethod must be registry or none."
}
```

- [ ] **Step 4: Add analyzer settings, CI workflow, and build gating**

```powershell
# PSScriptAnalyzerSettings.psd1
@{
    Severity = @('Error', 'Warning')
    IncludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSUseConsistentIndentation'
    )
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
    )
}
```

```yaml
# .github/workflows/powershell-validation.yml
name: PowerShell validation

on:
  push:
  pull_request:

jobs:
  validate:
    runs-on: windows-2022
    steps:
      - uses: actions/checkout@v4
      - name: Install analyzer
        shell: powershell
        run: |
          Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
          Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -AllowClobber
      - name: Run validation
        shell: powershell
        run: .\tests\Run-AllChecks.ps1
```

```powershell
# build-exe.ps1
$validationRunner = Join-Path $PSScriptRoot 'tests\Run-AllChecks.ps1'
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $validationRunner
if ($LASTEXITCODE -ne 0) {
    throw "Validation failed; refusing to build the EXE."
}
```

- [ ] **Step 5: Run the full validation task and fix the first breakages**

Run:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Run-AllChecks.ps1
```

Expected:

```text
[PASS] parse checks
[PASS] package validator
[PASS] help smoke test
[PASS] config smoke test
```

- [ ] **Step 6: Commit the validation harness**

```bash
git add .github/workflows/powershell-validation.yml PSScriptAnalyzerSettings.psd1 tests/Parse-AllPowerShell.ps1 tests/Run-AllChecks.ps1 tests/Validate-GDIDTool.ps1 TESTING.md build-exe.ps1
git commit -m "test: add Windows validation gates"
```

---

### Task 2: Harden Config Parsing And Migration

**Files:**
- Modify: `gdid-tool.ps1`
- Modify: `gdid-config.json`
- Test: `tests/Validate-GDIDTool.ps1`
- Test: `tests/Run-AllChecks.ps1`

- [ ] **Step 1: Write a failing config validation test**

```powershell
# add to tests/Validate-GDIDTool.ps1
$invalidConfig = @{
    schemaVersion = 2
    rotationMode = 'perBoot'
    blockCDP = 'false'
    blockHosts = $true
    hookMethod = 'api'
} | ConvertTo-Json

$tempPath = Join-Path $env:TEMP 'gdid-config-invalid.json'
Set-Content -LiteralPath $tempPath -Value $invalidConfig -Encoding UTF8

& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File (Join-Path $root 'gdid-tool.ps1') config schemaVersion `
    -ConfigPathOverride $tempPath

if ($LASTEXITCODE -eq 0) {
    throw 'Expected invalid config to fail validation.'
}
```

- [ ] **Step 2: Run the validator to confirm config migration is not implemented yet**

Run:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Validate-GDIDTool.ps1
```

Expected:

```text
FAIL because gdid-tool.ps1 does not yet expose strict schema validation and api rejection
```

- [ ] **Step 3: Add strict config helpers and migration in gdid-tool.ps1**

```powershell
# gdid-tool.ps1
$script:CurrentConfigSchema = 2
$script:DefaultConfig = @{
    schemaVersion = $script:CurrentConfigSchema
    rotationMode = 'onDemand'
    timedIntervalMin = 30
    blockCDP = $true
    blockHosts = $true
    killPhoneLink = $false
    killOneDrive = $false
    killStore = $false
    killTimeline = $false
    blockDO = $false
    hookMethod = 'registry'
}

function ConvertTo-StrictBoolean {
    param(
        [Parameter(Mandatory = $true)]
        $Value,
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if ($Value -is [bool]) { return $Value }

    switch -Regex ([string]$Value) {
        '^(?i:true)$' { return $true }
        '^(?i:false)$' { return $false }
        default { throw "Configuration '$Key' must be true or false." }
    }
}

function ConvertTo-RotationMode {
    param([Parameter(Mandatory = $true)]$Value)

    switch (([string]$Value).Trim()) {
        'onDemand' { return 'onDemand' }
        'timed' { return 'timed' }
        'perLogon' { return 'perLogon' }
        'perBoot' { return 'perLogon' }
        default { throw "rotationMode must be onDemand, timed, or perLogon." }
    }
}

function ConvertTo-HookMethod {
    param([Parameter(Mandatory = $true)]$Value)

    switch (([string]$Value).Trim()) {
        'registry' { return 'registry' }
        'none' { return 'none' }
        'api' { throw "hookMethod=api is unsupported in v2; use 'registry' or 'none'." }
        default { throw "hookMethod must be registry or none." }
    }
}
```

- [ ] **Step 4: Replace the config file with the v2 schema**

```json
{
  "schemaVersion": 2,
  "rotationMode": "onDemand",
  "timedIntervalMin": 30,
  "blockCDP": true,
  "blockHosts": true,
  "killPhoneLink": false,
  "killOneDrive": false,
  "killStore": false,
  "killTimeline": false,
  "blockDO": false,
  "hookMethod": "registry"
}
```

- [ ] **Step 5: Re-run the validator and smoke tests**

Run:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Validate-GDIDTool.ps1
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Run-AllChecks.ps1
```

Expected:

```text
[PASS] invalid config is rejected
[PASS] perBoot migrates to perLogon
[PASS] hookMethod=api is rejected
```

- [ ] **Step 6: Commit config hardening**

```bash
git add gdid-tool.ps1 gdid-config.json tests/Validate-GDIDTool.ps1 tests/Run-AllChecks.ps1
git commit -m "feat: harden config parsing and migration"
```

---

### Task 3: Separate Protected State And Runtime State

**Files:**
- Modify: `gdid-tool.ps1`
- Test: `tests/Validate-GDIDTool.ps1`
- Test: `tests/Run-AllChecks.ps1`

- [ ] **Step 1: Write a failing state-layout test**

```powershell
# add to tests/Validate-GDIDTool.ps1
$scriptText = Get-Content -LiteralPath (Join-Path $root 'gdid-tool.ps1') -Raw
foreach ($forbidden in "'originalGDID'", "'lastRotation'") {
    if ($scriptText -match [regex]::Escape($forbidden)) {
        throw "Legacy mixed-purpose config field still present: $forbidden"
    }
}
```

- [ ] **Step 2: Run the validator and confirm the legacy fields still exist**

Run:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Validate-GDIDTool.ps1
```

Expected:

```text
FAIL because originalGDID or lastRotation still exists in config handling
```

- [ ] **Step 3: Add explicit protected-state and runtime-state helpers**

```powershell
# gdid-tool.ps1
$script:ProgramDataRoot = if ($env:ProgramData) { $env:ProgramData } else { $PSScriptRoot }
$script:RuntimeRoot = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'GDIDPrivacy' } else { $PSScriptRoot }
$script:CurrentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:ProtectedStatePath = Join-Path (Join-Path $script:ProgramDataRoot 'GDIDPrivacy') "$($script:CurrentUserSid)-state.json"
$script:RuntimeStatePath = Join-Path $script:RuntimeRoot 'runtime.json'

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temp = "$Path.tmp"
    $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Save-ProtectedState {
    param([Parameter(Mandatory = $true)]$State)
    Write-JsonAtomic -Path $script:ProtectedStatePath -Value $State
}

function Save-RuntimeState {
    param([Parameter(Mandatory = $true)]$State)
    Write-JsonAtomic -Path $script:RuntimeStatePath -Value $State
}
```

- [ ] **Step 4: Update rotate/install/uninstall to use the new stores**

```powershell
# gdid-tool.ps1
$protectedState = @{
    schemaVersion = 1
    userSid = $script:CurrentUserSid
    originalLid = $original.hex
    hostsManaged = $cfg.blockHosts
}
Save-ProtectedState $protectedState

$runtimeState = @{
    lastOperation = 'rotate'
    lastMaskValue = $new
    lastVerifiedAt = (Get-Date).ToString('o')
}
Save-RuntimeState $runtimeState
```

- [ ] **Step 5: Re-run validation and read-only smoke tests**

Run:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Run-AllChecks.ps1
```

Expected:

```text
[PASS] validation runner completes
[PASS] legacy mutable backup fields are gone from config responsibilities
```

- [ ] **Step 6: Commit state separation**

```bash
git add gdid-tool.ps1 tests/Validate-GDIDTool.ps1 tests/Run-AllChecks.ps1
git commit -m "feat: separate protected state from runtime state"
```

---

### Task 4: Redesign Rotation And Scheduled Tasks

**Files:**
- Modify: `gdid-tool.ps1`
- Modify: `gdid-tool.bat`
- Test: `tests/Validate-GDIDTool.ps1`
- Test: `tests/Run-AllChecks.ps1`

- [ ] **Step 1: Write a failing task-behavior test**

```powershell
# add to tests/Validate-GDIDTool.ps1
$scriptText = Get-Content -LiteralPath (Join-Path $root 'gdid-tool.ps1') -Raw
foreach ($forbidden in 'RunLevel Highest', 'New-ScheduledTaskTrigger -AtStartup') {
    if ($scriptText -match [regex]::Escape($forbidden)) {
        throw "Legacy scheduled-task behavior still present: $forbidden"
    }
}
```

- [ ] **Step 2: Run validation and confirm the current task model fails**

Run:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Validate-GDIDTool.ps1
```

Expected:

```text
FAIL because gdid-tool.ps1 still uses highest privilege or AtStartup scheduling
```

- [ ] **Step 3: Replace the legacy task model with current-user scheduling**

```powershell
# gdid-tool.ps1
function Get-RotationTaskName {
    return 'GDIDRotator'
}

function Install-RotationTask {
    param([hashtable]$Config)

    if ($Config.rotationMode -eq 'onDemand') {
        Uninstall-RotationTask
        return
    }

    $taskName = Get-RotationTaskName
    $scriptPath = Join-Path $PSScriptRoot 'gdid-tool.ps1'
    $arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" rotate"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments

    if ($Config.rotationMode -eq 'perLogon') {
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    } else {
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes $Config.timedIntervalMin) `
            -RepetitionDuration ([TimeSpan]::MaxValue)
    }

    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
}
```

- [ ] **Step 4: Update rotate/status wording and the batch launcher**

```powershell
# gdid-tool.ps1
if ($cfg.blockCDP) {
    Write-Host "  [OK] Local mask applied and CDP is disabled." -ForegroundColor Green
    Write-Host "  [OK] Local mask is expected to persist locally." -ForegroundColor Green
} else {
    Write-Host "  [WARN] Local mask applied, but CDP is active." -ForegroundColor Yellow
    Write-Host "  [WARN] Windows may restore the previous value." -ForegroundColor Yellow
}
```

```bat
:: gdid-tool.bat
if /I "%MODE%"=="install" goto :ensure_admin
if /I "%MODE%"=="uninstall" goto :ensure_admin
goto :run
```

- [ ] **Step 5: Re-run validation and manual task smoke checks**

Run:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Run-AllChecks.ps1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\gdid-tool.ps1 help
```

Expected:

```text
[PASS] no highest-privilege scheduled task text remains
[PASS] help output still lists rotate/install/uninstall/config/status/help
```

- [ ] **Step 6: Commit the task redesign**

```bash
git add gdid-tool.ps1 gdid-tool.bat tests/Validate-GDIDTool.ps1 tests/Run-AllChecks.ps1
git commit -m "feat: redesign local rotation task behavior"
```

---

### Task 5: Tighten Install, Uninstall, HOSTS, And Status Verification

**Files:**
- Modify: `gdid-tool.ps1`
- Test: `tests/Validate-GDIDTool.ps1`
- Test: `tests/Run-AllChecks.ps1`

- [ ] **Step 1: Write a failing output-contract test**

```powershell
# add to tests/Validate-GDIDTool.ps1
$helpText = @(& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File (Join-Path $root 'gdid-tool.ps1') help 2>&1) -join "`n"

foreach ($forbiddenClaim in 'real GDID rotated','Identity changed everywhere','api | none') {
    if ($helpText -match [regex]::Escape($forbiddenClaim)) {
        throw "Help output still contains forbidden claim: $forbiddenClaim"
    }
}
```

- [ ] **Step 2: Run the validator to prove the old wording still leaks through**

Run:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Validate-GDIDTool.ps1
```

Expected:

```text
FAIL because help or output still overstates rotation or advertises api mode
```

- [ ] **Step 3: Update HOSTS management and install/uninstall verification**

```powershell
# gdid-tool.ps1
function Install-HostsBlocks {
    param([string[]]$Domains)

    $content = Get-Content -LiteralPath $script:HostsPath -Raw -ErrorAction Stop
    $content = $content -replace "(?ms)\r?\n?$([regex]::Escape($script:HostsBeginMarker)).*?$([regex]::Escape($script:HostsEndMarker))\r?\n?", ''

    $managed = @($script:HostsBeginMarker)
    foreach ($domain in $Domains) {
        $managed += "0.0.0.0 $domain"
    }
    $managed += $script:HostsEndMarker

    $newContent = $content.TrimEnd() + "`r`n" + ($managed -join "`r`n") + "`r`n"
    Set-Content -LiteralPath $script:HostsPath -Value $newContent -Encoding ASCII

    foreach ($domain in $Domains) {
        if ($newContent -notmatch "(?m)^0\.0\.0\.0\s+$([regex]::Escape($domain))$") {
            throw "HOSTS verification failed for domain '$domain'."
        }
    }
}
```

- [ ] **Step 4: Rewrite status/help output around local masking**

```powershell
# gdid-tool.ps1
function Show-Help {
    Write-Host @"
GDID Privacy Tool
  Local privacy hardening for Windows GDID-related values.

Modes:
  status       Show local values, CDP state, HOSTS blocks, and task state
  rotate       Apply a new local mask value to supported registry destinations
  install      Apply configured protections and verification
  uninstall    Remove tool-managed protections and restore backed-up state
  config       View or change configuration
  help         Show this help

Notes:
  This tool does not rotate Microsoft's authoritative server-side identity.
  If CDP remains active, Windows may restore the local value after rotation.
"@
}
```

- [ ] **Step 5: Run the full validation suite**

Run:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Run-AllChecks.ps1 -IncludeStatus
```

Expected:

```text
[PASS] help uses local-mask wording
[PASS] package validator passes
[PASS] status smoke test completes without overstated claims
```

- [ ] **Step 6: Commit verification and output hardening**

```bash
git add gdid-tool.ps1 tests/Validate-GDIDTool.ps1 tests/Run-AllChecks.ps1
git commit -m "feat: verify protections and harden status output"
```

---

### Task 6: Rewrite Docs And Remove API Hook From The Supported Surface

**Files:**
- Modify: `README.md`
- Create: `docs/MIGRATION-v2.md`
- Create: `docs/RELEASE-v2.md`
- Modify: `gdid-tool.ps1`
- Modify: `gdid-hook-dll/README.md`

- [ ] **Step 1: Write a failing documentation contract check**

```powershell
# add to tests/Validate-GDIDTool.ps1
$readme = Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw
foreach ($forbidden in 'server-assigned, not derived from hardware','hookMethod | `registry` / `api`','Mode 3') {
    if ($readme -match [regex]::Escape($forbidden)) {
        throw "README still advertises removed or unsupported behavior: $forbidden"
    }
}
```

- [ ] **Step 2: Run validation and confirm the old README still conflicts with v2**

Run:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Validate-GDIDTool.ps1
```

Expected:

```text
FAIL because README still describes api mode or stronger rotation claims
```

- [ ] **Step 3: Rewrite README and add migration/release notes**

```markdown
# README.md
## Overview

GDID Privacy Tool is a local privacy-hardening tool for Windows. It can inspect
and locally mask supported GDID-related registry values, disable CDP behavior as
configured, and add exact-name HOSTS blocks for selected endpoints.

## Limits

- Does not rotate Microsoft's authoritative server-side identity
- Does not guarantee that all Microsoft reporting paths are blocked
- Does not support API/AppInit hook mode in v2
```

```markdown
# docs/MIGRATION-v2.md
## Breaking Behavior Changes

- `perBoot` is migrated to `perLogon`
- `hookMethod=api` is rejected; use `registry` or `none`
- backup/runtime data no longer lives inside `gdid-config.json`
```

```markdown
# docs/RELEASE-v2.md
## Highlights

- truthful local-mask wording
- safer scheduled task model
- strict config validation
- Windows CI and validation harness
```

- [ ] **Step 4: Mark hook docs unsupported and remove api from help/config text**

```markdown
# gdid-hook-dll/README.md
## Support Status

This directory is retained only as historical research material during the v2
transition. `hookMethod=api` is not a supported product feature.
```

```powershell
# gdid-tool.ps1
Write-Host "  hookMethod         registry / none"
```

- [ ] **Step 5: Run the full validation suite one final time**

Run:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Run-AllChecks.ps1 -IncludeStatus
```

Expected:

```text
[PASS] README matches local-hardening positioning
[PASS] api mode no longer appears in supported docs or help
[PASS] validation suite stays green
```

- [ ] **Step 6: Commit the v2 documentation reset**

```bash
git add README.md docs/MIGRATION-v2.md docs/RELEASE-v2.md gdid-tool.ps1 gdid-hook-dll/README.md tests/Validate-GDIDTool.ps1
git commit -m "docs: rewrite v2 hardening guidance"
```

---

## Self-Review

### Spec Coverage

- Product repositioning: covered by Task 5 and Task 6.
- Truthful `rotate` semantics: covered by Task 4 and Task 5.
- Strict versioned config: covered by Task 2.
- Protected state and runtime-state separation: covered by Task 3.
- Non-elevated current-user rotation task: covered by Task 4.
- HOSTS verification and safe ownership boundaries: covered by Task 5.
- Windows CI and validation harness: covered by Task 1.
- Migration and release documentation: covered by Task 6.
- API hook deprecation/removal from supported surface: covered by Task 2 and Task 6.

### Placeholder Scan

- No deferred implementation markers remain in tasks.
- Each code-changing step includes concrete code snippets.
- Each test step includes an explicit command and expected result.

### Type Consistency

- `rotationMode` uses only `onDemand`, `timed`, and `perLogon`.
- `hookMethod` uses only `registry` and `none` in the supported path.
- State split consistently uses `ProtectedState` and `RuntimeState`.
