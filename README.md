<div align="center">

<img src="assets/app-icon.png" alt="SEAM" width="148" height="148">

<h1>SEAM</h1>

<p align="center">
  <strong>One cursor. Every screen.</strong><br/>
  Seamless, non-root mouse, keyboard, smooth scrolling, and clipboard sharing between <strong>macOS</strong>, <strong>Windows</strong> and <strong>Android</strong> — two desktop hosts, one shared Android agent.
</p>

<p align="center">
  <a href="https://github.com/Ferousco-dev/Seam/releases/download/v1.0.0/SEAM-macOS-arm64.dmg"><img src="assets/download-macos.svg" alt="Download for macOS • Includes Android Agent" height="58"></a>
  &nbsp;&nbsp;
  <a href="#windows-x64"><img src="https://img.shields.io/badge/Download_for_Windows_x64-Portable_ZIP_•_Experimental-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Download for Windows x64 — portable ZIP (experimental)" height="58"></a>
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B%20(Liquid%20Glass)-000000?style=flat-square&logo=apple&logoColor=white">
  <img alt="Android 11-15+" src="https://img.shields.io/badge/Android-11--15%2B%20(Non--Root)-3DDC84?style=flat-square&logo=android&logoColor=white">
  <img alt="Windows x64 (Experimental)" src="https://img.shields.io/badge/Windows-x64%20(Experimental)-0078D4?style=flat-square&logo=windows&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="Java 17" src="https://img.shields.io/badge/Java-17%20(d8%20DEX)-ED8B00?style=flat-square&logo=openjdk&logoColor=white">
  <img alt=".NET 8" src="https://img.shields.io/badge/.NET-8%20(C%23)-512BD4?style=flat-square&logo=dotnet&logoColor=white">
  <img alt="Linux UHID" src="https://img.shields.io/badge/Linux-%2Fdev%2Fuhid-FCC624?style=flat-square&logo=linux&logoColor=black">
  <a href="CONTRIBUTING.md"><img alt="PRs Welcome" src="https://img.shields.io/badge/PRs-welcome-brightgreen?style=flat-square"></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/License-MIT-2ea44f?style=flat-square"></a>
</p>

<p align="center">
  <a href="#what-is-seam">What is SEAM</a> •
  <a href="#downloads">Downloads</a> •
  <a href="#preview">Preview</a> •
  <a href="#install">Install</a> •
  <a href="#technology-stack">Technology Stack</a> •
  <a href="#how-it-works">How It Works</a> •
  <a href="#build-from-source">Build from Source</a> •
  <a href="#contributing">Contributing</a>
</p>

</div>

---

## What is SEAM?

**SEAM** brings an Apple Universal Control experience to **macOS, Windows and Android**.

Move your Mac cursor past the edge of your display and it flows directly onto your Android phone sitting beside your laptop. Unlike screen-mirroring tools (`scrcpy`) that trap your pointer inside a desktop video window, or accessibility-based apps that draw fake overlay cursors, SEAM registers real virtual hardware HID devices in Android's Linux kernel (`/dev/uhid`) without root. You get Android's genuine native hardware pointer, 120 Hz smooth trackpad scrolling, Mac keyboard shortcuts (`Cmd+C`, `Cmd+V`, `Opt+Arrows`, `Cmd+Arrows`), and automatic bidirectional clipboard sync over USB or Wi-Fi, all from a single desktop host with no Android app to install.

SEAM is one project in three parts: a **macOS host** (menu-bar app, the mature one), a **Windows
host** (.NET 8 console host, new and labelled **experimental**) and a single **Android companion
agent** that both hosts push to the phone. The wire protocol, the agent and the pairing scheme are
shared, so switching desktops does not change what runs on the phone.

---

## Downloads

| Desktop host | Package | Status |
|---|---|---|
| **macOS 14+** (Apple Silicon) | [`SEAM-macOS-arm64.dmg`](https://github.com/Ferousco-dev/Seam/releases/download/v1.0.0/SEAM-macOS-arm64.dmg) · [`SEAM-macOS-arm64.zip`](https://github.com/Ferousco-dev/Seam/releases/download/v1.0.0/SEAM-macOS-arm64.zip) | Stable |
| **Windows 10/11 x64** | `SEAM-Setup-x64.exe` (installer) or `SEAM-Windows-x64.zip` (portable) — see [below](#windows-x64) | **Experimental** |

Whichever desktop host you use, the **same Android companion agent** is pushed to the phone over ADB.
Nothing is installed on Android — no APK, no root.

---

### Windows x64

**Installer or portable ZIP. Nothing else to install:** both packages contain a self-contained .NET 8
`win-x64` build *and* Android Platform-Tools (`adb.exe`), so they need **no .NET SDK, no .NET runtime,
no Android SDK, no PATH edits and no manual downloads** — run the installer, or unzip and run.

> **Windows support is experimental.** The host compiles and passes its offline self-test in CI, but
> it has **not yet been exercised on a physical Windows desktop or against a physical phone**. Expect
> rough edges on the first runs and read [`windows-host/README.md`](windows-host/README.md) for the
> precise list of what is and is not verified.

**Where to download it.** There is intentionally **no Windows GitHub Release yet** — both packages
are built by CI and attached to the run as artifacts:

1. Open **[Actions → Windows build](https://github.com/CalebPiusC/Seam/actions/workflows/windows-build.yml)**.
2. Select the newest **green** run and download **`SEAM-Setup-x64.exe`** (installer) and/or
   **`SEAM-Windows-x64.zip`** (portable) from its *Artifacts* section.
3. Prefer to build it yourself? The **Run workflow** button on that page builds it on demand; the
   same workflow also runs automatically on pull requests and on `arena/**` development branches.

**SEAM for Windows is a normal Windows application.** There is nothing to run from a terminal: you
start it the way you start any other program, and the SEAM window is the whole interface.

**Install or unzip**

1. **Installer:** run `SEAM-Setup-x64.exe`, then open **SEAM** from the Start Menu (or from the
   desktop shortcut if you ticked that box during setup). The shortcut points straight at the
   application — no arguments, no console, no script.
2. **Portable:** unzip `SEAM-Windows-x64.zip` and **double-click `seam-host.exe`** inside the
   `SEAM-Windows-x64` folder. Keep that folder intact — the executable expects `seam-agent.jar`,
   `platform-tools\` and its runtime DLLs beside it — but you can move the whole folder anywhere,
   including a path with spaces.
3. **SmartScreen, once.** The builds are **not code-signed**, so the first launch of the installer,
   or of a `seam-host.exe` that came out of a downloaded ZIP, shows *"Windows protected your PC"*.
   Click **More info → Run anyway**. Windows remembers the decision for that file. This is the only
   security prompt SEAM triggers; there is no UAC prompt when the application itself starts.

**Using the window**

1. Enable **USB debugging** on the phone (see *Phone requirements* below) and plug it in; tap
   **ALLOW** on the phone.
2. SEAM shows the phone within a couple of seconds — it does not need a phone to open, and it never
   shows a blank window while it looks.
3. Press **Connect**. SEAM pushes and starts the shared Android agent, authenticates with mutual
   HMAC-SHA256, and the status pill turns green.
4. Move the pointer to the screen edge named in the window (right by default) to take control of the
   phone. **`Ctrl + Alt + Q`** always hands control back to Windows.
5. Settings (edge, auto-connect, activity length) live in `%APPDATA%\SEAM\ui-settings.json`;
   **Diagnostics** in the window (or *SEAM diagnostics* in the Start Menu) prints every path SEAM
   searched and what ADB reports. Closing the window ends the session and removes the input hooks.

**Optional: diagnostics and advanced use (PowerShell)**

The commands below are **never needed to use SEAM** — the window covers normal use. They exist for
troubleshooting, for scripted checks, and for the older console-only workflow.

```powershell
# Nothing here touches the network and nothing printed is secret.
.\seam-host.exe --diagnose     # app folder, adb, agent jar, devices; ends with "RESULT: all bundled resources found."
.\seam-host.exe --self-test    # offline protocol/auth/frame self-check, no phone needed
.\seam-host.exe --help         # every option, including --edge, --connect, --device, --jar, --adb

# Console-only session (the pre-window workflow, still supported):
.\seam-host.exe --trajectory   # pushes + starts the agent and streams a scripted path: proves the link
.\seam-host.exe --capture      # routes input to Android on the first mouse movement; `q` quits, `r` returns
```

`adb.exe` is bundled in `platform-tools\` and `seam-agent.jar` sits next to `seam-host.exe`, so
everything above resolves from the folder containing the executable — never from the current
directory, `PATH` or `%TEMP%` — whichever way you launched it. `Get-Adb.ps1` remains in the package
as an optional **repair** tool if `platform-tools\` is missing or corrupt.

**Phone requirements**

- Android 11+ with **USB debugging** enabled (Settings → About phone → tap *Build number* seven
  times → Developer options → *USB debugging*), and the **Allow USB debugging?** prompt accepted on
  the phone.
- Windows usually needs an **OEM ADB USB driver**. Many vendors (Transsion/TECNO/Infinix, some
  Motorola and Xiaomi models) ship none, and the phone simply never appears in `adb devices`.
  **Wireless debugging** (Developer options → *Wireless debugging* → *Pair device with pairing code*)
  avoids the driver problem entirely; `--connect <phone-ip>:27186` also bypasses ADB once the agent
  is running.
- Test on a **single monitor** first — multi-monitor geometry is not handled yet. While routing,
  SEAM installs system-wide low-level mouse/keyboard hooks and swallows input for the phone; UAC
  prompts and the lock screen are invisible to those hooks by design.

**What is in the ZIP**

The archive is **flat** — extracting it gives you one `SEAM-Windows-x64` folder with these files
directly inside, with no second folder of the same name to click through:

```text
SEAM-Windows-x64/
├── seam-host.exe            the host
├── *.dll, hostfxr.dll,      self-contained .NET 8 runtime (keep them with the exe)
│   coreclr.dll
├── seam-agent.jar           the shared Android agent, compiled from this repo
├── platform-tools\           Android Platform-Tools: adb.exe + 2 DLLs, used from here
├── Get-Adb.ps1              optional repair tool (re-downloads Platform-Tools)
├── README-WINDOWS.txt       quick start, printed for offline reading
├── THIRD-PARTY-NOTICES.md   what is bundled and under which licence
├── BUILD-INFO.txt           commit, runner, SDK versions, SHA-256s
└── LICENSE                  MIT
```

The **installer** (`SEAM-Setup-x64.exe`) ships the same files to `C:\Program Files\SEAM`, adds
Start Menu shortcuts (including a *SEAM diagnostics* one), registers SEAM in **Installed apps**, and
comes with an uninstaller that keeps your pairing key unless you explicitly say otherwise. Upgrade
and uninstall behaviour, plus a troubleshooting table, are in
[`windows-host/INSTALL.md`](windows-host/INSTALL.md).

---

### macOS

Download **[`SEAM-macOS-arm64.dmg`](https://github.com/Ferousco-dev/Seam/releases/download/v1.0.0/SEAM-macOS-arm64.dmg)**
(or the [`.zip`](https://github.com/Ferousco-dev/Seam/releases/download/v1.0.0/SEAM-macOS-arm64.zip))
from the [latest GitHub Release](https://github.com/Ferousco-dev/Seam/releases/latest), then follow
**[Mac Setup](#1-mac-setup)**. Requires macOS 14+ on Apple Silicon; builds are ad-hoc signed rather
than notarized, so use right-click → **Open** on first launch. The macOS host is the mature
implementation: menu-bar UI, arrangement flyout, UDP fast path and clipboard sync.

---

### Android (shared by both hosts)

Both desktop hosts use the **same** `seam-agent.jar` — a ~32 KB zero-Gradle DEX daemon that
registers a 16-bit relative HID mouse and a 6KRO HID keyboard through `/dev/uhid` (non-root,
`uid=2000`), launched with `app_process`. The host pushes and starts it automatically; the only
setup on the phone is enabling **USB debugging** (or Wireless debugging) once. See
**[Android Setup](#3-android-setup-automatic-zero-apk)**.

---

## Preview

<div align="center">
  <table>
    <tr>
      <td align="center" width="54%">
        <img src="assets/seam-demo.gif" alt="SEAM Menu-Bar Liquid Glass Popover &amp; Drag Arrangement Demo" width="440">
        <br/><br/>
        <sub><strong>macOS Menu-Bar Popover:</strong> Liquid Glass UI &amp; drag-to-arrange display layout (<a href="assets/seam-demo.mp4">MP4</a> · <a href="assets/seam-demo.mov">MOV</a>)</sub>
      </td>
      <td align="center" width="46%">
        <img src="assets/android-native-cursor.jpg" alt="Genuine Android Native Mouse Pointer Sprite via /dev/uhid" width="340">
        <br/><br/>
        <sub><strong>Android Screen:</strong> Genuine native hardware cursor sprite driven via <code>/dev/uhid</code> (no root, no screen mirroring)</sub>
      </td>
    </tr>
  </table>
  <br/>
  <video src="assets/seam-demo.mp4" width="520" controls autoplay loop muted playsinline></video>
</div>

---

## Install

### 1. Mac Setup
1. Download **[SEAM-macOS-arm64.dmg](https://github.com/Ferousco-dev/Seam/releases/download/v1.0.0/SEAM-macOS-arm64.dmg)** (or **[SEAM-macOS-arm64.zip](https://github.com/Ferousco-dev/Seam/releases/download/v1.0.0/SEAM-macOS-arm64.zip)**) from the [latest GitHub Release](https://github.com/Ferousco-dev/Seam/releases/latest).
2. Open the disk image and drag **SEAM** into **Applications**.
3. On first launch, right-click **SEAM.app** → **Open** (builds are ad-hoc signed, not notarized with an Apple Developer ID).
4. Look for the **laptop & iPhone** icon in your macOS menu bar.

### 2. Windows Setup (Experimental)
1. Download **either** `SEAM-Setup-x64.exe` (installer: Start Menu entry, *Installed apps* registration, uninstaller) **or** `SEAM-Windows-x64.zip` (portable: unzip anywhere) — see **[Windows x64](#windows-x64)** for the artifact links. No .NET SDK, runtime, Android SDK or Visual Studio is needed, and nothing has to be added to `PATH`.
2. Run `seam-host.exe --diagnose` in the install folder (or from the *SEAM diagnostics* Start Menu entry). It should end with `RESULT: all bundled resources found.` — `adb.exe` ships inside `platform-tools\` and `seam-agent.jar` next to the exe.
3. Enable **USB debugging** on the phone and accept the *Allow USB debugging?* prompt when you plug it in (Wireless debugging also works, and needs no OEM USB driver).
4. Run `seam-host.exe --self-test`, then `seam-host.exe --trajectory` to prove the link, then `seam-host.exe --capture` for real control. **`Ctrl + Alt + Q`** returns control to Windows.

Install, upgrade, uninstall and troubleshooting: [`windows-host/INSTALL.md`](windows-host/INSTALL.md).
Physical-hardware checklist: [`windows-host/MANUAL-VERIFICATION.md`](windows-host/MANUAL-VERIFICATION.md).

The OEM-driver caveat, the exact package contents and the current limitations are all in
**[Windows x64](#windows-x64)**.

### 3. Android Setup (Automatic, Zero APK)
1. Enable **USB Debugging** (or **Wireless Debugging**) once under Android **Developer Options**.
2. Plug your phone in for a moment (or connect via Wireless Debugging). **SEAM Auto-Pilot** automatically pushes the `32 KB` `seam-agent.jar` agent, starts the `/dev/uhid` virtual mouse & keyboard, and attaches both **USB** and **Wi-Fi** links.
3. Unplug anytime: the background daemon keeps Wi-Fi (`TCP/UDP 27186`) ready for cable-free reconnection.
4. *(Optional)* Grant **SEAM** permission in **System Settings → Privacy & Security → Accessibility** to enable global `CGEventTap` capture alongside the built-in non-activating panel fallback.

The same `seam-agent.jar` is used by the Windows host; neither desktop needs an APK on the phone.

### Controls & Shortcuts
- **Edge Crossing:** Move your pointer past the side where you positioned your phone. Drag either tile inside the menu-bar popover to match your desk.
- **Mac-Style Editing on Android:** `Cmd+C` / `Cmd+V` / `Cmd+X` / `Cmd+A` / `Cmd+Z`, `Cmd+Left/Right` (line start/end), `Cmd+Up/Down` (document top/bottom), `Opt+Left/Right` (word jump), `Opt+Backspace` (delete word).
- **Emergency Return to Mac:** **`Ctrl + Option + Q`** or **`Ctrl + Option + Cmd + Esc`**.
- **Emergency Return to Windows:** **`Ctrl + Alt + Q`** (Windows host); `q` quits the console, `r` forces a return.

---

## Technology Stack

| Icon | Technology | Role in SEAM |
|:---:|---|---|
| <img src="https://img.shields.io/badge/-Swift_6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6"> | **Swift 6** | Native macOS host daemon, wire protocol serializer, hotkey & shortcut translator |
| <img src="https://img.shields.io/badge/-SwiftUI_%26_Liquid_Glass-007AFF?style=flat-square&logo=apple&logoColor=white" alt="SwiftUI & Liquid Glass"> | **SwiftUI & Apple Liquid Glass** | Menu-bar popover (`GlassEffectContainer`, `.glassEffect`, `.buttonStyle(.glass)` on macOS 26+ with vibrancy fallback) and interactive `ArrangementView` |
| <img src="https://img.shields.io/badge/-AppKit_%26_Quartz-555555?style=flat-square&logo=apple&logoColor=white" alt="AppKit & Quartz"> | **AppKit & Quartz Event Services** | `NSStatusBar`, `CGEventTap`, `CGAssociateMouseAndMouseCursorPosition`, and non-activating `CaptureShieldPanel` (`NSPanel`) |
| <img src="https://img.shields.io/badge/-C%23_%26_.NET_8-512BD4?style=flat-square&logo=dotnet&logoColor=white" alt="C# & .NET 8"> | **C# & .NET 8 (P/Invoke)** | Windows host: `WH_MOUSE_LL` / `WH_KEYBOARD_LL` hooks, `SetCursorPos` re-centring with a `ClipCursor` guard, per-monitor-v2 DPI, published as a self-contained `win-x64` folder (`adb` + agent bundled) |
| <img src="https://img.shields.io/badge/-Apple_Icon_Composer-1C1C1E?style=flat-square&logo=apple&logoColor=white" alt="Icon Composer"> | **Apple Icon Composer** | Multi-layer Liquid Glass app icon (`AppIcon.icon`) compiled with `ictool` and `actool` into `AppIcon.icns` & `Assets.car` |
| <img src="https://img.shields.io/badge/-Java_17_%26_d8-ED8B00?style=flat-square&logo=openjdk&logoColor=white" alt="Java 17 & d8"> | **Java 17 + Android SDK `d8`** | Zero-Gradle `32 KB` DEX daemon (`dist/seam-agent.jar`) launched via `app_process` (`uid=2000`) |
| <img src="https://img.shields.io/badge/-Linux_%2Fdev%2Fuhid-FCC624?style=flat-square&logo=linux&logoColor=black" alt="Linux /dev/uhid"> | **Linux Kernel `/dev/uhid`** | Registers a 16-bit relative HID Mouse and 6KRO HID Keyboard (`UHID_CREATE2` / `UHID_INPUT2`) directly with `InputReader` |
| <img src="https://img.shields.io/badge/-AOSP_Binder-3DDC84?style=flat-square&logo=android&logoColor=white" alt="Android Binder"> | **Android `InputManagerGlobal` & `IClipboard`** | Injects 120 Hz fractional `MotionEvent.ACTION_SCROLL` events and syncs system clipboard changes via silent timestamp inspection |
| <img src="https://img.shields.io/badge/-HMAC--SHA256-2E7D32?style=flat-square&logo=letsencrypt&logoColor=white" alt="HMAC-SHA256"> | **CryptoKit & `javax.crypto`** | Mutual HMAC-SHA256 session handshake (`SEAM-Wire v1`) and authenticated 42-byte UDP mouse delta datagrams |
| <img src="https://img.shields.io/badge/-USB_%2B_Wi--Fi-0A84FF?style=flat-square&logo=wifi&logoColor=white" alt="Dual Transport"> | **ADB Socket + Hybrid TCP/UDP** | Concurrent USB (`localabstract:seam_uhid`) & Wi-Fi (`TCP/UDP 27186`) multiplexer with automatic cable-pull failover |

---

## How It Works

### System Architecture

```mermaid
flowchart TB
    subgraph macOS["macOS Host (SEAM.app, Menu Bar)"]
        direction LR
        UI["SeamMenuBarController & ArrangementView<br/>(Liquid Glass Popover, Drag-to-Arrange)"]
        HID["Physical Trackpad, Mouse & Keyboard"]
        Quartz["QuartzEdgeEngine<br/>(CGEventTap / CaptureShieldPanel)"]
        CursorCtrl["BackgroundCursorController<br/>(Decouple & Hide Mac Cursor)"]
        KeyMap["MacKeycodeTranslator<br/>(Cmd->Ctrl, Opt/Cmd Navigation)"]
        ClipMac["MacClipboardSyncEngine<br/>(NSPasteboard Watcher)"]
        Mux["SeamTransportMultiplexer<br/>(CryptoKit HMAC-SHA256 & Auto-Failover)"]

        UI -->|"Edge Position"| Quartz
        HID --> Quartz
        Quartz --> CursorCtrl
        Quartz --> KeyMap
        Quartz -->|"Hi-Res Scroll & Pointer Deltas"| Mux
        KeyMap -->|"6KRO HID Key Reports"| Mux
        ClipMac <-->|"OP_CLIPBOARD_SET / EVENT"| Mux
    end

    subgraph Transport["Dual Authenticated Transport (SEAM-Wire v1)"]
        direction LR
        USB["UsbAdbTransport<br/>ADB localabstract:seam_uhid<br/>SO_PEERCRED uid=2000 + HMAC-SHA256"]
        WIFI["WifiHybridTransport<br/>TCP Control (Port 27186)<br/>+ 42B Signed UDP Fast-Path"]
    end

    Mux <==>|"Primary / Hot Standby"| USB
    Mux <==>|"Primary / Hot Standby (< 10 ms Failover)"| WIFI

    subgraph Android["Android Background Agent (seam_agent, Zero-APK uid=2000)"]
        direction LR
        Coord["DualTransportCoordinator<br/>(UsbLocalSocketServer + WifiTransportServer)"]
        Engine["SeamInputEngine<br/>(Curve Velocity Shadow Tracker & Edge Return)"]
        UHID["Linux /dev/uhid<br/>(16-bit Relative Mouse + 6KRO Keyboard)"]
        AOSP["AOSP InputReader & PointerController<br/>(Native Hardware Cursor Sprite)"]
        Scroll["SmoothScrollInjector<br/>(InputManagerGlobal 120 Hz ACTION_SCROLL)"]
        ClipAnd["AndroidClipboardController<br/>(IClipboard Binder + Silent Timestamp Check)"]
        Display["DisplayTelemetry<br/>(DisplayManagerGlobal Metrics & Rotation)"]

        Coord <--> Engine
        Engine -->|"UHID_INPUT2"| UHID
        UHID --> AOSP
        Engine -->|"1/32-Notch Fractional Scroll"| Scroll
        Engine <-->|"Bidirectional Sync"| ClipAnd
        Display --> Engine
    end

    USB <==>|"Encrypted Stream"| Coord
    WIFI <==>|"Encrypted TCP + Signed UDP"| Coord
```

### What Happens When Your Cursor Crosses Over

```mermaid
sequenceDiagram
    autonumber
    participant Mac as macOS Host (SEAM.app)
    participant Link as USB / Wi-Fi (SEAM-Wire v1)
    participant Phone as Android Agent (seam_agent)
    participant OS as Android Kernel & System

    Mac->>Link: Mutual HMAC-SHA256 Handshake
    Link->>Phone: Authenticate Session (USB + Wi-Fi Standby)
    Phone-->>Mac: OP_DISPLAY_INFO (Resolution, DPI, Rotation)

    Note over Mac,Phone: You move your pointer past the configured Mac screen edge
    Mac->>Mac: Decouple & hide Mac cursor (no warp bounce)
    Mac->>Link: OP_CURSOR_ENTER + OP_CLIPBOARD_SET (sync Mac clipboard)
    Link->>Phone: Home pointer & update Android IClipboard
    Phone->>OS: /dev/uhid mouse report + IClipboard.setPrimaryClip

    loop Active Control on Android (120 Hz)
        Mac->>Link: Mouse Deltas & 1/32-Notch Scroll (42B Signed UDP / USB)
        Link->>Phone: Deliver Input Frame
        Phone->>OS: /dev/uhid Pointer Sprite + SmoothScrollInjector ACTION_SCROLL
        Mac->>Link: Keyboard Shortcuts (Cmd+C / Cmd+V -> Ctrl+C / Ctrl+V)
        Phone->>OS: /dev/uhid 6KRO Key Report
    end

    Note over Phone,OS: Copy on Android or push pointer back to the return bezel
    OS-->>Phone: IOnPrimaryClipChangedListener -> OP_CLIPBOARD_EVENT
    Phone-->>Mac: Sync copied text to NSPasteboard
    Phone-->>Mac: OP_EDGE_RETURN (exit Y ratio)
    Mac->>Mac: Restore & show Mac cursor at matching edge height
```

### Repository Structure

```text
SEAM/
├── README.md
├── Makefile
├── assets/
│   ├── app-icon.png                  # Exported 1024×1024 Icon Composer AppIcon
│   ├── android-native-cursor.jpg     # Native Android hardware pointer screenshot
│   ├── seam-demo.gif                 # Animated demo preview
│   ├── seam-demo.mp4                 # 60 fps H.264 demo clip
│   ├── seam-demo.mov                 # Original screen recording
│   ├── download-macos.svg
│   └── windows-soon.svg
├── release/
│   ├── SEAM-macOS-arm64.dmg          # Ready-to-install macOS disk image (bundles Android agent)
│   └── SEAM-macOS-arm64.zip          # Portable zipped SEAM.app bundle
├── scripts/
│   ├── build-agent.sh                # Zero-Gradle DEX compiler (javac + Android SDK d8)
│   └── build-host.sh                 # Swift release build, Icon Composer export & SEAM.app bundler
├── macos-host/
│   ├── Package.swift
│   ├── Resources/AppIcon.icon/       # Apple Icon Composer document (laptopcomputer.and.iphone)
│   └── Sources/SeamHost/
│       ├── Main.swift                # App & CLI entrypoint (app, edge, devices, usb/wifi/switch tests)
│       ├── UI/                       # SeamMenuBarController, SeamPopoverView, ArrangementView, LiquidGlass, SeamAppViewModel
│       ├── Input/                    # QuartzEdgeEngine, BackgroundCursorController, MacKeycodeTranslator, MacClipboardSyncEngine
│       ├── Protocol/                 # SeamWireProtocol & CryptoKit SeamAuthenticator
│       ├── Transport/                # SeamTransport, UsbAdbTransport, WifiHybridTransport & SeamTransportMultiplexer
│       └── Bootstrap/                # UsbBootstrapper (ADB / Wireless Debugging / mDNS / LAN probe)
├── android-agent/
│   └── src/main/java/com/seam/agent/
│       ├── Main.java                 # Daemon & diagnostics CLI (--server, --info, --self-test, --calibrate)
│       ├── core/                     # SeamInputEngine
│       ├── clipboard/                # AndroidClipboardController
│       ├── pointer/                  # PointerLinearizer & SmoothScrollInjector
│       ├── protocol/                 # SeamProtocol & SeamAuthenticator
│       ├── transport/                # DualTransportCoordinator, UsbLocalSocketServer, WifiTransportServer
│       ├── uhid/                     # UhidDevice, HidDescriptors, HidKeycodes
│       └── telemetry/                # DisplayTelemetry, DisplayMetricsSnapshot, NetworkTelemetry
├── windows-host/                     # Windows desktop host (.NET 8, self-contained folder build)
│   ├── Program.cs                    # CLI: --self-test, --diagnose, --trajectory, --capture, --edge, --connect
│   ├── Host/AppLayout.cs             # app-relative discovery of adb.exe + seam-agent.jar
│   ├── Protocol/                     # SEAM-Wire v1 frames + HMAC-SHA256 authenticator
│   ├── Transport/                    # TCP session, frame reader, 500 ms heartbeat
│   ├── Input/                        # Low-level mouse/keyboard hooks, edge crossing, HID key table
│   ├── Bootstrap/                    # adb discovery, push/launch, tcp:0 → localabstract forward
│   ├── Testing/                      # In-process loopback agent + offline self-test
│   ├── packaging/                    # shipped docs, repair helper, icon, third-party notices
│   └── installer/                    # Inno Setup script → SEAM-Setup-x64.exe
├── .github/workflows/
│   └── windows-build.yml             # compile → self-test → publish → ZIP + installer → install/uninstall test
├── tools/                            # Protocol parity, OpenSSL vector check, Python device simulator
└── research/                         # Architecture specifications & protocol notes
```

---

## Build from Source

### Prerequisites
- **macOS 14+** (Apple Silicon `arm64`) with **Xcode** (provides `Icon Composer` / `ictool` / `actool`) and Swift 6+
- **JDK 17+** (`javac`) and **Android SDK** (`adb`, `d8`, `platforms/android-35/android.jar` in `~/Library/Android/sdk`)
- **Android 11–15+ Device** (non-root) with USB Debugging or Wireless Debugging enabled

### Build & Run
```bash
# Compile Android DEX agent (dist/seam-agent.jar), Swift host (dist/seam-host), and dist/SEAM.app
make build

# Launch SEAM in the macOS Menu Bar
open dist/SEAM.app
```

### Windows Host

Requires the [.NET 8 SDK](https://dotnet.microsoft.com/download) — nothing else for the host itself.
The Android agent JAR additionally needs **JDK 17+** and the Android SDK (`platforms/android-35/android.jar` and `d8`).

```powershell
cd windows-host
dotnet build -c Release
dotnet run -- --self-test          # offline protocol/auth/frame/resource tests, no phone needed
dotnet run -- --diagnose           # what it resolved for adb, agent jar and pairing key

# the same self-contained app folder CI ships (NOT single-file: see windows-host/README.md)
dotnet publish -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=false -o ..\build\app
```

CI (`.github/workflows/windows-build.yml`, `windows-latest`) builds `seam-agent.jar` with
`javac`/`d8`, adds it plus `platform-tools\` and the docs to `build\app`, runs `--diagnose` and
`--self-test` from that folder, from `C:\` and from a path with spaces, builds
`SEAM-Windows-x64.zip` (hash-compared against `build\app`) and `SEAM-Setup-x64.exe` from the same
folder, then **silently installs the app, runs it from `Program Files`, reinstalls over it and
uninstalls it** before uploading both artifacts.

### Diagnostic & Transport Verification Targets
```bash
make edge           # Terminal-based macOS <-> Android edge-crossing session
make devices        # List discovered Android devices
make usb-test       # Benchmark USB ADB socket transport & mutual auth
make wifi-test      # Benchmark Wi-Fi Hybrid (TCP + 42B HMAC-SHA256 UDP) transport
make switch-test    # Test live zero-downtime USB <-> Wi-Fi switching & failover
make device-info    # Inspect display geometry, /dev/uhid & PointerChoreographer
make self-test      # Run on-device /dev/uhid cursor & keyboard self-test
make calibrate      # Verify 16-bit corner homing & velocity control calibration
```

See [`research/README.md`](research/README.md) for deep technical specifications.

---

## Contributing

SEAM is open to pull requests, bug reports, and hardware compatibility feedback (especially Windows host support and testing across Android OEMs). See **[CONTRIBUTING.md](CONTRIBUTING.md)** for setup steps, verification commands, and PR guidelines.

---

## License

Distributed under the **[MIT License](LICENSE)**.
