# GDID API Hook DLL (Mode 3)

Hooks `RegQueryValueExW` at the Win32 API layer. Instead of modifying registry values, this DLL intercepts reads to the GDID registry keys at runtime and returns a spoofed value — the real GDID stays untouched on disk.

## How It Works

```
Process (CDPSvc / any app)
  │  calls RegQueryValueExW("LID")
  ▼
gdid-hook.dll  ← intercepts
  │  matches target path + value name
  │  generates fake 0018-prefixed 64-bit hex
  ▼ returns spoofed value
Caller gets fake GDID (real value untouched)
```

Uses [MinHook](https://github.com/TsudaKageyu/minhook) (MIT license) for API hooking — minimal, tested, x86/x64.

## Build

### With CMake (recommended)

```powershell
cmake -B build
cmake --build build --config Release
# Output: build/bin/gdid-hook.dll
```

### With MSBuild (Visual Studio)

```powershell
git submodule update --init
msbuild gdid-hook.vcxproj /p:Configuration=Release /p:Platform=x64
```

## Install

### Via AppInit_DLLs (global, affects all processes)

```powershell
# Set DLL path
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows" `
  /v AppInit_DLLs /t REG_SZ /d "C:\path\to\gdid-hook.dll" /f
# Enable loading
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows" `
  /v LoadAppInit_DLLs /t REG_DWORD /d 1 /f
# Require signed DLLs (0 = disabled)
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows" `
  /v RequireSignedAppInit_DLLs /t REG_DWORD /d 0 /f

# Reboot or restart target processes
```

### Via injection into CDPSvc (targeted)

```powershell
# Using a simple injector (e.g., CreateRemoteThread)
# Or via gdid-tool.ps1: .\gdid-tool.ps1 config hookMethod api
```

## Detection Risk

- `AppInit_DLLs` is well-known and flagged by many EDR/AV products
- Alternative: use `SetWindowsHookEx` or reflective DLL injection into `CDPSvc.exe` only
- Most users should stick with Mode 2 (registry rotation + firewall) instead

## Exported Functions

| Function | Purpose |
|----------|---------|
| `InstallHooks()` | Enable the RegQueryValueExW hook |
| `RemoveHooks()` | Disable and remove all hooks |
| `EnableLogging(BOOL)` | Toggle debug output to DebugView |
| `ToggleHooks(BOOL)` | Install (TRUE) or remove (FALSE) hooks