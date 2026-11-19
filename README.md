<div align="center">

<img src="assets/app-icon.png" alt="SEAM" width="148" height="148">

<h1>SEAM</h1>

<p align="center">
  <strong>One cursor. Every screen.</strong><br/>
  Seamless, non-root mouse, keyboard, smooth scrolling, and clipboard sharing between <strong>macOS</strong> and <strong>Android</strong>, with <strong>Windows</strong> coming next.
</p>

<p align="center">
  <a href="https://github.com/Ferousco-dev/Seam/releases/download/v1.0.0/SEAM-macOS-arm64.dmg"><img src="assets/download-macos.svg" alt="Download for macOS • Includes Android Agent" height="58"></a>
  &nbsp;&nbsp;
  <img src="assets/windows-soon.svg" alt="Coming soon for Windows" height="58">
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B%20(Liquid%20Glass)-000000?style=flat-square&logo=apple&logoColor=white">
  <img alt="Android 11-15+" src="https://img.shields.io/badge/Android-11--15%2B%20(Non--Root)-3DDC84?style=flat-square&logo=android&logoColor=white">
  <img alt="Windows Soon" src="https://img.shields.io/badge/Windows-Coming%20Soon-0078D4?style=flat-square&logo=windows&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="Java 17" src="https://img.shields.io/badge/Java-17%20(d8%20DEX)-ED8B00?style=flat-square&logo=openjdk&logoColor=white">
  <img alt="Linux UHID" src="https://img.shields.io/badge/Linux-%2Fdev%2Fuhid-FCC624?style=flat-square&logo=linux&logoColor=black">
  <a href="CONTRIBUTING.md"><img alt="PRs Welcome" src="https://img.shields.io/badge/PRs-welcome-brightgreen?style=flat-square"></a>
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/License-MIT-2ea44f?style=flat-square"></a>
</p>

<p align="center">
  <a href="#what-is-seam">What is SEAM</a> •
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

**SEAM** brings an Apple Universal Control experience to **macOS and Android** (with Windows support coming next).

Move your Mac cursor past the edge of your display and it flows directly onto your Android phone sitting beside your laptop. Unlike screen-mirroring tools (`scrcpy`) that trap your pointer inside a desktop video window, or accessibility-based apps that draw fake overlay cursors, SEAM registers real virtual hardware HID devices in Android's Linux kernel (`/dev/uhid`) without root. You get Android's genuine native hardware pointer, 120 Hz smooth trackpad scrolling, Mac keyboard shortcuts (`Cmd+C`, `Cmd+V`, `Opt+Arrows`, `Cmd+Arrows`), and automatic bidirectional clipboard sync over USB or Wi-Fi, all from a single macOS menu-bar icon with no Android app to install.

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

### 2. Android Setup (Automatic, Zero APK)
1. Enable **USB Debugging** (or **Wireless Debugging**) once under Android **Developer Options**.
2. Plug your phone in for a moment (or connect via Wireless Debugging). **SEAM Auto-Pilot** automatically pushes the `32 KB` `seam-agent.jar` agent, starts the `/dev/uhid` virtual mouse & keyboard, and attaches both **USB** and **Wi-Fi** links.
3. Unplug anytime: the background daemon keeps Wi-Fi (`TCP/UDP 27186`) ready for cable-free reconnection.
4. *(Optional)* Grant **SEAM** permission in **System Settings → Privacy & Security → Accessibility** to enable global `CGEventTap` capture alongside the built-in non-activating panel fallback.

### Controls & Shortcuts
- **Edge Crossing:** Move your pointer past the side where you positioned your phone. Drag either tile inside the menu-bar popover to match your desk.
- **Mac-Style Editing on Android:** `Cmd+C` / `Cmd+V` / `Cmd+X` / `Cmd+A` / `Cmd+Z`, `Cmd+Left/Right` (line start/end), `Cmd+Up/Down` (document top/bottom), `Opt+Left/Right` (word jump), `Opt+Backspace` (delete word).
- **Emergency Return to Mac:** **`Ctrl + Option + Q`** or **`Ctrl + Option + Cmd + Esc`**.

---

## Technology Stack

| Icon | Technology | Role in SEAM |
|:---:|---|---|
| <img src="https://img.shields.io/badge/-Swift_6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6"> | **Swift 6** | Native macOS host daemon, wire protocol serializer, hotkey & shortcut translator |
| <img src="https://img.shields.io/badge/-SwiftUI_%26_Liquid_Glass-007AFF?style=flat-square&logo=apple&logoColor=white" alt="SwiftUI & Liquid Glass"> | **SwiftUI & Apple Liquid Glass** | Menu-bar popover (`GlassEffectContainer`, `.glassEffect`, `.buttonStyle(.glass)` on macOS 26+ with vibrancy fallback) and interactive `ArrangementView` |
| <img src="https://img.shields.io/badge/-AppKit_%26_Quartz-555555?style=flat-square&logo=apple&logoColor=white" alt="AppKit & Quartz"> | **AppKit & Quartz Event Services** | `NSStatusBar`, `CGEventTap`, `CGAssociateMouseAndMouseCursorPosition`, and non-activating `CaptureShieldPanel` (`NSPanel`) |
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
