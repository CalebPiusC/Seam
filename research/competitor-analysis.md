# OSINT Competitor & Prior-Art Architectural Analysis

> **Scope:** Source-level investigation of `scrcpy`, `Deskflow` / `Input Leap` / `Barrier` / `Synergy`, `KDE Connect`, and Apple `Universal Control`—analyzing their architectures, wire protocols, limitations, what SEAM must adopt, and the critical technical gaps SEAM exploits.

---

## 1. Architectural Comparison Matrix

| System | Primary Paradigm | macOS Capture Mechanism | Android Input Mechanism | Native Android Mouse Cursor? | Seamless Edge Transition (No Mirror Window)? | Works Over USB & Wi-Fi? |
| :--- | :--- | :--- | :--- | :---: | :---: | :---: |
| **SEAM (Target)** | **Cross-OS Spatial Peripheral Bridge** | `CGEventTap` + `CGAssociateMouseAndMouseCursorPosition(false)` | **`/dev/uhid` (`app_process` `uid=2000`) + AOAv2 fallback** | **Yes (`PointerController`)** | **Yes (Screen-Edge Crossing)** | **Yes (Both)** |
| **scrcpy** (v3.x) | Desktop Video Mirroring + OTG Control | SDL2 window capture (relative mode on click) | `InputManager` (`--mouse=sdk`), `/dev/uhid` (`--mouse=uhid`), or `AOAv2` (`--otg`) | Only in `uhid`/`aoa` modes | **No** (Requires clicking inside an SDL2 window on Mac) | Yes (`uhid` over ADB USB/Wi-Fi; `aoa` USB only) |
| **Deskflow / Input Leap / Barrier / Synergy** | Desktop-to-Desktop Software KVM | `CGEventTapCreate` + `OSXScreen.mm` background cursor hide | Experimental Android client uses `AccessibilityService.dispatchGesture()` + Fake Overlay | **No** (Draws fake overlay `ImageView` on Android; touch gestures only) | Yes (Desktop-to-Desktop), **Partial/Broken on Android** | Wi-Fi TCP only (No USB ADB/UHID) |
| **KDE Connect** | Companion Remote Touchpad / Notifications | Trackpad window inside macOS app | `AccessibilityService.dispatchGesture()` (Android as receiver) | **No** (Touch simulation only) | **No** (Requires dragging inside a remote touchpad window) | Wi-Fi TLS only |
| **Apple Universal Control** | Apple-Ecosystem Spatial HID Continuity | Private WindowServer / SkyLight HID routing | **None (iOS/iPadOS/macOS only)** | N/A (iPadOS cursor only) | Yes | Wi-Fi Direct / USB (Apple only) |
| **Samsung Flow / Link to Windows** | OEM-Locked Mirroring / Multi-Control | Windows-only (`Samsung Multi Control`) | OEM System App (`INJECT_EVENTS` / System UID 1000) | Only on Samsung Galaxy Book + OneUI | Only on Windows + Samsung hardware | Wi-Fi / BT |

---

## 2. Deep Dive into Each Project

### 2.1 `scrcpy` (Genymobile)
- **Repository:** https://github.com/Genymobile/scrcpy
- **Architecture Inspected:**
  - `app/src/control_msg.c`: Defines a compact binary control protocol over an ADB-forwarded local socket (`localabstract:scrcpy`).
  - `server/src/main/java/com/genymobile/scrcpy/uhid/UhidManager.java`: Deployed via `adb shell CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server`. Opens `/dev/uhid` using `android.system.Os.open("/dev/uhid", OsConstants.O_RDWR, 0)` as `uid=2000 (shell)` and writes `UHID_CREATE2` and `UHID_INPUT2` packets.
  - `app/src/usb/aoa_hid.c`: Implements `--otg` mode via `libusb` control transfers (`ACCESSORY_REGISTER_HID = 54`, `ACCESSORY_SET_HID_REPORT_DESC = 56`, `ACCESSORY_SEND_HID_EVENT = 57`).
- **Limitations of `scrcpy` (Even in `--otg` or `--no-video --mouse=uhid` Mode):**
  1. **Window-Bound Capture:** Even when run with `scrcpy --otg` or `scrcpy --no-video -M -K`, `scrcpy` opens a dummy SDL2 window on the macOS desktop. The user must manually click into the SDL2 window to trap the mouse, and press a keyboard shortcut (`Alt` or `Super`) to release the mouse back to macOS.
  2. **Zero Screen-Edge Awareness:** `scrcpy` has no concept of where the Android phone sits physically relative to the MacBook display, does not use a global macOS `CGEventTap` at the screen edge, and cannot detect when the Android cursor reaches the phone's screen edge to automatically release focus back to macOS!
  3. **8-Bit Relative HID Descriptor (`-127` to `+127`):** `scrcpy`'s `UhidManager` uses a standard 8-bit relative mouse descriptor without corner-homing or closed-loop entry coordinate synchronization.
- **What SEAM Learns & Exploits:**
  - We **adopt** `scrcpy`'s battle-tested `app_process` deployment pattern (`uid=2000` opening `/dev/uhid` via `android.system.Os` and accessing `IClipboard` via Binder reflection).
  - We **replace** `scrcpy`'s SDL2 window trap with a global macOS Quartz `CGEventTap` spatial edge engine and upgrade `/dev/uhid` to a **16-bit relative mouse descriptor with corner-homing and closed-loop return-edge telemetry**.

---

### 2.2 `Deskflow` / `Input Leap` / `Barrier` / `Synergy`
- **Repositories:**
  - Deskflow: https://github.com/deskflow/deskflow
  - Input Leap: https://github.com/input-leap/input-leap
  - Barrier: https://github.com/debauchee/barrier
  - Synergy Android Client (`synergy-android` / `deskflow-android`): https://github.com/symless/synergy-android
- **Architecture Inspected:**
  - `src/lib/platform/OSXScreen.mm` & `OSXEventQueueBuffer.cpp`: The gold standard for macOS global input capture. Uses `CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, ...)`, `CGAssociateMouseAndMouseCursorPosition(false)`, `CGWarpMouseCursorPosition`, and `CGSSetConnectionProperty(..., CFSTR("SetsCursorInBackground"), kCFBooleanTrue)` to hide the cursor while in the background.
  - Wire Protocol (`ProtocolTypes.cpp`): TCP-based packet protocol (`DMMV` for mouse move, `DMDN`/`DMUP` for mouse button, `DKDN`/`DKUP` for key down/up, `CINN` for enter screen with entry coordinates, `COUT` for leave screen).
- **Why Synergy / Barrier / Deskflow Fail on Android:**
  1. **Root or Accessibility Hack on Android:** Historically, `synergy-android` required a **rooted Android phone** with `chmod 666 /dev/uinput` to create a virtual mouse. Because modern users do not root Android 15 phones, newer Android ports switched to `AccessibilityService.dispatchGesture()` + a fake floating `WindowManager` cursor overlay.
  2. **Broken UX of Accessibility Overlays:** As analyzed in [android-input-architecture.md](file:///Users/oresajooluwaferanmiidunuoluwa/Desktop/PROJECTS/SEAM/research/android-input-architecture.md), an Accessibility overlay cursor cannot trigger native Android hover states, cannot scroll naturally with a scroll wheel, gets blocked by Android 12–15 untrusted-touch security policies on system dialogs, and stutters during drags.
  3. **TCP Head-of-Line Blocking:** The classic Synergy protocol sends every mouse movement packet (`DMMV`) over a single TCP stream, causing noticeable cursor jitter on Wi-Fi whenever a single packet is retransmitted.
- **What SEAM Learns & Exploits:**
  - We **adopt** `OSXScreen.mm`'s proven macOS Quartz event tap and cursor decoupling lifecycle (`CGAssociateMouseAndMouseCursorPosition` + `SetsCursorInBackground`).
  - We **solve** Deskflow/Barrier's fatal Android flaw by routing Android input through **`/dev/uhid` (`uid=2000`)** instead of `AccessibilityService` or root `/dev/uinput`, delivering the **100% genuine native Android hardware cursor** without root!

---

### 2.3 `KDE Connect`
- **Repositories:**
  - Android: https://github.com/KDE/kdeconnect-android
  - Desktop/macOS: https://github.com/KDE/kdeconnect-kde
- **Architecture Inspected:**
  - Uses UDP broadcast port `1716` for discovery and TLS sockets on ports `1716–1764` with TOFU (Trust On First Use) self-signed ECDSA/RSA X.509 certificate pinning (`SslHelper.java`).
  - `MouseReceiverPlugin.java`: Uses an `AccessibilityService` (`MouseReceiverService.java`) to inject simulated finger taps/swipes via `dispatchGesture()`.
- **Limitations:**
  - Designed primarily for the phone to control the computer (`MousePadPlugin`), not the computer's cursor seamlessly crossing a screen edge onto the phone.
  - When controlling the phone from the desktop, it relies on `AccessibilityService` touch gestures with no native mouse cursor.
- **What SEAM Learns & Exploits:**
  - KDE Connect's **TOFU Mutual TLS Certificate Pinning** model (generating device certificates stored in macOS Keychain and Android Keystore, verified once via pairing fingerprint/QR code) is clean, resilient, and zero-configuration for Phase 2 Wi-Fi support.

---

### 2.4 Apple `Universal Control` (macOS + iPadOS)
- **Architecture & UX Benchmark:**
  - Discovers nearby devices via BLE proximity + mDNS, negotiates an encrypted peer-to-peer link over AWDL (Apple Wireless Direct Link) or USB (`usbmuxd`), and provides an iconic **"push-through edge resistance"** animation before the cursor pops onto the adjacent screen.
  - Dynamically matches physical vertical inches between the Mac display and the iPad display.
- **Gap SEAM Exploits:**
  - Apple strictly locks Universal Control to Apple ID-authenticated macOS and iPadOS devices. There is **no official or open-source Universal Control equivalent linking macOS (Apple Silicon) and Android 15** with a native hardware cursor. SEAM fills this exact gap.
