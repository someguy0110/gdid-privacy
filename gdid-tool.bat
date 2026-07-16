@echo off
setlocal
REM GDID Privacy Tool - double-click launcher (auto-elevates to Administrator)

REM /elevated marks a relaunch we already triggered below. Checking it first
REM guarantees we NEVER try to elevate twice, no matter what: this is what
REM stops the endless "cascading window" loop some users hit.
if /I "%~1"=="/elevated" (
    shift
    goto :run
)

REM Detect admin rights via an ACL probe instead of "net session": net.exe's
REM session query depends on the Server (LanmanServer) service, which some
REM trimmed-down/debloated Windows installs disable. On those machines
REM "net session" always errors out regardless of elevation, so the old
REM check believed it was never Administrator and kept relaunching itself
REM elevated forever, spawning a new window each time. cacls has no such
REM service dependency.
>nul 2>&1 "%SystemRoot%\System32\cacls.exe" "%SystemRoot%\System32\config\system"
if %errorLevel% equ 0 goto :run

PowerShell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '/elevated %*' -Verb RunAs"
exit /b

:run
set "ARGS=%*"
if "%~1"=="" set "ARGS=install"
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gdid-tool.ps1" %ARGS%
endlocal
