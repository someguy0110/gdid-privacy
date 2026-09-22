<#
    build-exe.ps1 — Compile gdid-tool.ps1 into a standalone gdid-tool.exe
    Requires Windows + PowerShell. Run as Administrator.

    What it does:
      1. Installs the ps12exe module (if missing)
      2. Compiles gdid-tool.ps1 -> gdid-tool.exe
         The packaging options live in gdid-tool.ps1 as directives:
         `#_pragma App.Windowed` (no console window on double-click)
         `#_pragma Os.Admin`      (triggers a UAC prompt automatically)

    The resulting gdid-tool.exe can be double-clicked. It defaults to `install`
    (the .bat-style behaviour is compiled in via the script's own param defaults),
    or run from a prompt:  gdid-tool.exe status
#>

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable ps12exe)) {
    Install-Module ps12exe -Scope CurrentUser -Force
}

$src = Join-Path $PSScriptRoot 'gdid-tool.ps1'
$out = Join-Path $PSScriptRoot 'gdid-tool.exe'

if (-not (Test-Path $src)) {
    Write-Error "Cannot find gdid-tool.ps1 next to this script."
    exit 1
}

ps12exe -inputFile $src -outputFile $out

Write-Host "Built: $out" -ForegroundColor Green
Write-Host "Keep gdid-config.json (optional) in the same folder as the .exe." -ForegroundColor Yellow
