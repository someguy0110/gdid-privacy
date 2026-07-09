<div align="center">
  <br/>
  <h1>🛡️ GDID Privacy Tool</h1>
  <p><strong>View · Rotate · Spoof · Block</strong> — Windows Global Device Identifier tracking</p>
  <br/>

  [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
  [![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-0078d6)](https://github.com)
  [![Language](https://img.shields.io/badge/Language-PowerShell-5391FE)](https://github.com)
  [![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)](https://github.com)
  [![Maintained](https://img.shields.io/badge/Maintained-yes-2ea44f)](https://github.com)

  <br/>

  <img src="https://img.shields.io/badge/Based%20on-RE%20research%20of%20wlidsvc.dll%20%E2%86%92%20cdp.dll%20%E2%86%92%20DDS-8A2BE2" alt="RE Research"/>

  <br/>
  <br/>
</div>

---

## 📋 Overview

The **GDID (Global Device Identifier)** is a persistent 64-bit device ID that Microsoft assigns to every Windows installation. It's used across the Connected Devices Platform, Delivery Optimization, and Microsoft telemetry to track devices — even **without** a Microsoft Account login.

This tool gives you **control** over that identifier on **your own machine**.

<div align="center">
  <br/>
  <pre style="background: #0d1117; padding: 16px; border-radius: 8px;">
    <span style="color: #58a6ff;">.\gdid-tool.ps1 status</span>     → Show current GDID
    <span style="color: #58a6ff;">.\gdid-tool.ps1 rotate</span>     → Spoof a new ID now
    <span style="color: #58a6ff;">.\gdid-tool.ps1 install</span>    → Lock it down
    <span style="color: #58a6ff;">.\gdid-tool.ps1 uninstall</span>  → Restore defaults
  </pre>
  <br/>
</div>

---

## 🔬 How GDID Works

Based on full reverse engineering of the Windows identity stack (see the [original research](https://github.com/SmtimesIWndr/gdid-reversal)):

```
wlidsvc.dll  ──provision──→  login.live.com  ──assigns──→  64-bit Device PUID
       │                                                          │
       └───────── stores ─────────────────────────────────────────┘
                                    │
                                    ▼
                    HKCU\...\IdentityCRL\ExtendedProperties\LID
                                    │
                    cdp.dll (CDPSvc) reads it
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
           dds.microsoft.com  activity.windows.com  Delivery Optimization
           (Device Directory   (Activity History)   (UCDOStatus.GlobalDeviceId)
            Service)
```

| Detail | Value |
|--------|-------|
| **Type** | 64-bit Device PUID (Passport Unique ID) |
| **Prefix** | `0018` (device class), `0003` (user class) |
| **Assigned by** | `login.live.com` during MSA provisioning (SOAP `<ps:DevicePUID>`) |
| **Stored at** | `HKCU\SOFTWARE\Microsoft\IdentityCRL\ExtendedProperties\LID` |
| **Also at** | `HKCU\SOFTWARE\Microsoft\IdentityCRL\Immersive\production\Token\{GUID}\DeviceId` |
| **Reported by** | Delivery Optimization as `UCDOStatus.GlobalDeviceId` |
| **Persists** | Across Windows updates — changes only on **reinstall** |
| **Local-only?** | **No** — CDP still creates an anonymous device identity even without an MSA login, and reports it to the same endpoints |

> **Key insight:** GDID is **server-assigned**, not derived from hardware. A reinstall gets a new one. The client provisions with `login.live.com` and stores whatever PUID the server returns.

---

## 🚀 Quick Start

### Requirements
- Windows 10 or Windows 11
- PowerShell 5.1+ (run as **Administrator**)

### Install

**Option A — Clone with Git (PowerShell or CMD):**

```powershell
git clone https://github.com/someguy0110/gdid-tool.git
cd gdid-tool
```

**Option B — Download the script only (no Git needed):**

PowerShell:
```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/someguy0110/gdid-tool/main/gdid-tool.ps1" -OutFile "gdid-tool.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/someguy0110/gdid-tool/main/gdid-config.json" -OutFile "gdid-config.json"
```

CMD:
```cmd
curl -LO https://raw.githubusercontent.com/someguy0110/gdid-tool/main/gdid-tool.ps1
curl -LO https://raw.githubusercontent.com/someguy0110/gdid-tool/main/gdid-config.json
```

Then run (as Administrator):
```powershell
.\gdid-tool.ps1 install
```

> **Quick fix — "There's nothing to open .ps1 with" / script won't run:**
> This happens when you double-click the `.ps1` file (Windows doesn't associate `.ps1` with PowerShell) or when scripts are blocked by policy. Don't double-click. Open **PowerShell as Administrator**, then paste this one line (adjust the path):
> ```powershell
> powershell -ExecutionPolicy Bypass -File "C:\path\to\gdid-tool\gdid-tool.ps1" install
> ```
> This launches the script directly through PowerShell, bypassing both the file-association dialog and the execution-policy block.

That's it. The tool will:
1. Read your current GDID
2. Generate and write a fake one
3. Clear local CDP state
4. Restart CDP services
5. Add firewall rules to block the tracking endpoints
6. Create a scheduled task for automatic rotation

### Verify

```powershell
.\gdid-tool.ps1 status
```

---

## 🪟 Easy Options (No Terminal Needed)

### 1. Double-click launcher (`.bat`)
Just double-click **`gdid-tool.bat`**. It automatically asks for Administrator (UAC) and runs `install`. To use other commands, run it from a prompt or pass arguments:
```cmd
gdid-tool.bat status
gdid-tool.bat rotate
```

### 2. Standalone `.exe`
Two ways to get `gdid-tool.exe`:

- **Download (recommended):** grab `gdid-tool.exe` from the [Releases](https://github.com/someguy0110/gdid-tool/releases) page. Double-click it — it elevates and installs by default.
- **Build it yourself:** run `build-exe.ps1` (requires Windows + PowerShell, run as Administrator). It uses [ps2exe](https://github.com/MScholtes/PS2EXE) to compile the script:
  ```powershell
  .\build-exe.ps1
  ```
  To produce a downloadable `.exe` on every release, point a GitHub Actions workflow at `.\build-exe.ps1`.

> ⚠️ **Antivirus note:** `ps2exe` wrappers are sometimes flagged by AV because the same technique is abused by malware. The binary is safe and fully open-source (you can read `gdid-tool.ps1` yourself), but you may need to allow-list it. An unsigned `.exe` is more likely to be flagged than the `.ps1`.

### 3. Runs automatically when your PC starts
`install` already sets this up for you — it creates a Windows **scheduled task** called **`GDIDRotator`** that fires **AtStartup** (and on the rotation timer). Verify it:
```powershell
.\gdid-tool.ps1 status        # "Scheduled Task: GDIDRotator: Ready"
Get-ScheduledTask -TaskName "GDIDRotator"
```
To see it visually: `taskschd.msc` → Task Scheduler Library → **GDIDRotator**.

Alternative (manual) startup method — the **Startup folder**:
1. Press `Win+R`, type `shell:startup`, Enter
2. Put a shortcut to `gdid-tool.bat` (or `gdid-tool.exe`) there
3. It launches on every login — but run `install` once as Administrator first so the changes persist

> The scheduled-task method (the default) is better: it runs elevated at boot without a login, and rotates the GDID on the timer you configured.

---

## 📖 Commands

| Command | Description |
|---------|-------------|
| `status` | Show current GDID, service state, firewall rules, feature kills |
| `rotate` | Immediately generate and apply a new fake GDID |
| `install` | Apply all protections per current config |
| `uninstall` | Remove all changes, restore defaults |
| `config` | Show full configuration |
| `config <key>` | Show single config value |
| `config <key> <val>` | Set a config value |
| `help` | Print usage |

---

## ⚙️ Configuration

Edit `gdid-config.json` or use `.\gdid-tool.ps1 config <key> <value>`:

### Rotation

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `rotationMode` | `perBoot` / `timed` / `onDemand` | `perBoot` | When to auto-rotate the GDID |
| `timedIntervalMin` | number | `30` | Minutes between rotations (timed mode) |

### Network Blocking

| Key | Default | What it blocks |
|-----|---------|----------------|
| `blockDDS` | `true` | `dds.microsoft.com`, `fd.dds.microsoft.com`, `aad.cs.dds.microsoft.com`, `cdpcs.access.microsoft.com` |
| `blockActivity` | `true` | `activity.windows.com`, `cdn.activity.windows.com` |

### Feature Kill Switches

Toggle these to disable specific Microsoft services that use or depend on the GDID ecosystem:

| Key | Default | Disables |
|-----|---------|----------|
| `killPhoneLink` | `false` | Phone Link (Your Phone) app |
| `killOneDrive` | `false` | OneDrive file sync |
| `killStore` | `false` | Microsoft Store auto-updates |
| `killTimeline` | `false` | Activity History / Timeline |
| `blockCDP` | `false` | CDPSvc / CDPUserSvc entirely |

### Advanced

| Key | Values | Default | Description |
|-----|--------|---------|-------------|
| `hookMethod` | `registry` / `api` | `registry` | Spoof method — `registry` rewrites values, `api` uses DLL hooking |

### Examples

```powershell
# Rotate every 15 minutes
.\gdid-tool.ps1 config rotationMode timed
.\gdid-tool.ps1 config timedIntervalMin 15

# Kill Phone Link + disable CDP entirely
.\gdid-tool.ps1 config killPhoneLink true
.\gdid-tool.ps1 config blockCDP true

# Apply changes
.\gdid-tool.ps1 install
```

---

## 🎯 What Gets Blocked

| Feature | Collateral Damage |
|---------|-------------------|
| `blockDDS` | Cross-device clipboard, "Continue on PC", Nearby Share |
| `blockCDP` | All of the above + any CDP-dependent apps |
| `killPhoneLink` | Your Phone / Phone Link app stops working |
| `killOneDrive` | OneDrive won't sync files |
| `killStore` | App updates require manual trigger in Settings |
| `killTimeline` | Timeline history stops uploading |

---

## 🔄 How Rotation Works

1. **Generate** a random 64-bit hex string with the `0018` prefix (valid Device PUID namespace)
2. **Write** to both registry locations (`ExtendedProperties\LID` + `Token\{GUID}\DeviceId`)
3. **Clear** `%LOCALAPPDATA%\ConnectedDevicesPlatform` (stale CDP state cache)
4. **Restart** CDP services (forces re-registration with DDS using the fake ID)
5. **Block** re-provisioning endpoints via Windows Firewall

The server sees whatever fake ID the tool wrote — the change is local and propagates upward into the Device Directory Service.

---

## 🧪 Verification

```powershell
# Check current GDID value
(Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\IdentityCRL\ExtendedProperties').LID

# Check firewall rules
Get-NetFirewallRule | Where-Object DisplayName -like "*GDID*"

# Check scheduled task
Get-ScheduledTask -TaskName "GDIDRotator"

# Check CDP state cache
Get-ChildItem "$env:LOCALAPPDATA\ConnectedDevicesPlatform"

# Check service status
Get-Service CDPSvc, CDPUserSvc | Format-Table Name, Status, StartType -AutoSize
```

---

## 💻 For Developers: API Hook Mode (Advanced)

An optional DLL hook using [MinHook](https://github.com/TsudaKageyu/minhook) that intercepts `RegQueryValueExW` at the Win32 API layer. Instead of modifying registry values, it returns a spoofed value on read — the real GDID stays untouched.

```powershell
# Build
cd gdid-hook-dll
msbuild gdid-hook.vcxproj /p:Configuration=Release /p:Platform=x64

# Install via AppInit_DLLs
# See gdid-hook-dll/README.md for instructions
```

> ⚠️ **Warning:** `AppInit_DLLs` is widely flagged by AV/EDR products. Most users should stick with the default registry rotation mode.

---

## 🧠 Caveats

- **GDID is server-assigned.** Rotation changes the local value, but the server assigned the original. The firewall prevents the server from re-registering the real ID or rejecting the fake one.
- **CDP has an anonymous path — signing out of MSA does *not* make you private.** Many people assume "I never signed into a Microsoft Account, so Microsoft can't track my device." That's wrong: the Connected Devices Platform (CDP) still generates a stable **anonymous device identity** for local features like Nearby Share and "Continue on PC". That anonymous ID is reported to the same backend endpoints (`dds.microsoft.com`, etc.) as the full GDID. This tool's firewall rules block those endpoints **regardless of whether you're signed in**, so both the MSA-linked ID and the anonymous path are cut off.
- **Windows Updates may reset policies.** After a major Windows update, re-run `.\gdid-tool.ps1 install` to re-apply.

---

## 📚 References

- [gdid-reversal](https://github.com/SmtimesIWndr/gdid-reversal) — Complete reverse engineering writeup of the Windows GDID
- *United States v. Peter Stokes*, N.D. Ill., July 2026 — The DOJ complaint that first named GDID publicly

---

<div align="center">
  <br/>
  <sub>
    Built for <strong>defensive privacy</strong> — you own your device,
    you decide what it reports.
  </sub>
  <br/>
  <br/>
</div>