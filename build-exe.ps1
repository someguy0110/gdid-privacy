<# 
    build-exe.ps1 — Compile gdid-tool.ps1 into a standalone gdid-tool.exe
    Requires Windows + PowerShell. Run as Administrator.

    What it does:
      1. Installs the ps2exe module (if missing)
      2. Compiles gdid-tool.ps1 -> gdid-tool.exe
         -noConsole   : no black window on double-click
         -requireAdmin : triggers a UAC prompt automatically

    The resulting gdid-tool.exe can be double-clicked. It defaults to `install`
    (the .bat-style behaviour is compiled in via the script's own param defaults),
    or run from a prompt:  gdid-tool.exe status

    NOTE: GDIDRotator-hidden.vbs is also required for scheduled tasks to work
          without showing a console window.
#>

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable ps2exe)) {
    Install-Module ps2exe -Scope CurrentUser -Force
}

$src = Join-Path $PSScriptRoot 'gdid-tool.ps1'
$out = Join-Path $PSScriptRoot 'gdid-tool.exe'

if (-not (Test-Path $src)) {
    Write-Error "Cannot find gdid-tool.ps1 next to this script."
    exit 1
}

# Copy required supporting files to the output directory
$supportingFiles = @(
    Join-Path $PSScriptRoot 'gdid-config.json'
    Join-Path $PSScriptRoot 'GDIDRotator-hidden.vbs'
)

foreach ($file in $supportingFiles) {
    if (Test-Path $file) {
        Copy-Item -Path $file -Destination $PSScriptRoot -Force
        Write-Host "Copied: $(Split-Path $file -Leaf)" -ForegroundColor DarkGray
    }
}

Invoke-PS2EXE -InputFile $src -OutputFile $out -noConsole -requireAdmin

Write-Host "Built: $out" -ForegroundColor Green
Write-Host "Keep gdid-config.json and GDIDRotator-hidden.vbs (optional) in the same folder as the .exe." -ForegroundColor Yellow