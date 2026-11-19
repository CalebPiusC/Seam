# Technical References & Source Bibliography

> **Scope:** Authoritative index of official Android Open Source Project (AOSP) source files, Apple Developer documentation, Linux kernel specifications, and open-source reference implementations cited across the SEAM research corpus.

---

## 1. Android Input Architecture & AOSP Source Code

1. **Android Input Subsystem Official Documentation**
   - URL: https://source.android.com/docs/core/interaction/input
   - Relevance: Overview of `EventHub`, `InputReader`, `InputMapper`, and `InputDispatcher`.
2. **AOSP `EventHub.cpp` (`InputFlinger`)**
   - URL: https://android.googlesource.com/platform/frameworks/native/+/refs/heads/main/services/inputflinger/reader/EventHub.cpp
   - Relevance: Kernel `/dev/input/eventX` device discovery via `inotify`/`epoll` and `InputDeviceClass::CURSOR` classification rules (`REL_X`, `REL_Y`, `BTN_MOUSE`).
3. **AOSP `CursorInputMapper.cpp` (`InputFlinger`)**
   - URL: https://android.googlesource.com/platform/frameworks/native/+/refs/heads/main/services/inputflinger/reader/mapper/CursorInputMapper.cpp
   - Relevance: Proves that Android's cursor mapper requires relative `EV_REL` (`REL_X`, `REL_Y`) events to drive the hardware mouse cursor and ignores `EV_ABS` absolute coordinates.
4. **AOSP `TouchInputMapper.cpp` (`InputFlinger`)**
   - URL: https://android.googlesource.com/platform/frameworks/native/+/refs/heads/main/services/inputflinger/reader/mapper/TouchInputMapper.cpp
   - Relevance: Documents `DEVICE_MODE_DIRECT` vs. `DEVICE_MODE_POINTER` and why absolute HID digitizers act as touchscreens/styluses rather than rendering a mouse arrow pointer.
5. **AOSP `PointerChoreographer.cpp` (Android 14 / Android 15)**
   - URL: https://android.googlesource.com/platform/frameworks/native/+/refs/heads/main/services/inputflinger/PointerChoreographer.cpp
   - Relevance: New Android 14/15 component sitting between `InputReader` and `InputDispatcher` that manages `PointerController` instances, viewport clamping, and cursor visibility.
6. **AOSP `PointerController.cpp` (`libs/input`)**
   - URL: https://android.googlesource.com/platform/frameworks/native/+/refs/heads/main/libs/input/PointerController.cpp
   - Relevance: The native class that renders the hardware mouse cursor sprite onto `SurfaceFlinger` via `SpriteController`.
7. **AOSP `VelocityControl.cpp` (`libs/input`)**
   - URL: https://android.googlesource.com/platform/frameworks/native/+/refs/heads/main/libs/input/VelocityControl.cpp
   - Relevance: Implements Android's mouse pointer acceleration curve and the Android 14/15 flat/unaccelerated pointer mode (`MOUSE_POINTER_ACCELERATION_ENABLED`).
8. **AOSP `ueventd.rc` (`/dev/uhid` Device Node Permissions)**
   - URL: https://android.googlesource.com/platform/system/core/+/refs/heads/main/rootdir/ueventd.rc
   - Relevance: Confirms `/dev/uhid` is created with `0660 uhid uhid` (`gid=3011`), accessible by the non-root `shell` user (`uid=2000`).
9. **Android 15 Behavior Changes (All Apps & API 35)**
   - URL: https://developer.android.com/about/versions/15/behavior-changes-all
   - Relevance: Documents Android 15 input routing, foreground service requirements (`connectedDevice`), and background execution constraints.
10. **Android Security — Untrusted Touch Events Blocking (Android 12–15)**
    - URL: https://source.android.com/docs/security/test/untrusted-touch
    - Relevance: Explains why `TYPE_APPLICATION_OVERLAY` windows block touches unless `FLAG_NOT_TOUCHABLE` or restricted to a 1px edge bezel, and why kernel `/dev/uhid` devices are treated as trusted physical hardware.

---

## 2. Linux Kernel UHID & USB HID Specifications

11. **Linux Kernel UHID (`Documentation/hid/uhid.rst`)**
    - URL: https://www.kernel.org/doc/html/latest/hid/uhid.html
    - Relevance: Official documentation for user-space HID device creation via `/dev/uhid`.
12. **Linux Kernel `include/uapi/linux/uhid.h`**
    - URL: https://github.com/torvalds/linux/blob/master/include/uapi/linux/uhid.h
    - Relevance: Exact C struct layouts for `uhid_event`, `uhid_create2_req` (`UHID_CREATE2 = 11`), and `uhid_input2_req` (`UHID_INPUT2 = 12`).
13. **USB HID Usage Tables Specification (v1.5)**
    - URL: https://www.usb.org/document-library/hid-usage-tables-15
    - Relevance: Defines Generic Desktop Page (`0x01`), Mouse (`0x02`), Keyboard/Keypad Page (`0x07`), Wheel (`0x38`), and Consumer Page (`0x0C`) AC Pan (`0x0238`).
14. **Android Open Accessory Protocol 2.0 (AOAv2)**
    - URL: https://source.android.com/docs/core/interaction/accessories/aoa2
    - Relevance: Official specification for `ACCESSORY_REGISTER_HID` (54), `ACCESSORY_UNREGISTER_HID` (55), `ACCESSORY_SET_HID_REPORT_DESC` (56), and `ACCESSORY_SEND_HID_EVENT` (57).

---

## 3. macOS CoreGraphics, IOKit & TCC Security Documentation

15. **Apple Developer Documentation — `CGEventTapCreate`**
    - URL: https://developer.apple.com/documentation/coregraphics/1454426-cgeventtapcreate
    - Relevance: Creating active filter event taps (`kCGEventTapOptionDefault`) at `kCGHIDEventTap` or `kCGSessionEventTap`.
16. **Apple Developer Documentation — `CGAssociateMouseAndMouseCursorPosition`**
    - URL: https://developer.apple.com/documentation/coregraphics/1454386-cgassociatemouseandmousecursorpo
    - Relevance: Decoupling physical mouse movement from the on-screen macOS cursor position while continuing to receive `kCGMouseEventDeltaX` and `kCGMouseEventDeltaY`.
17. **Apple Developer Documentation — `CGWarpMouseCursorPosition`**
    - URL: https://developer.apple.com/documentation/coregraphics/1454357-cgwarpmousecursorposition
    - Relevance: Programmatically repositioning the macOS cursor upon returning from the Android screen edge.
18. **Apple Developer Documentation — `CGEventSourceSetLocalEventsSuppressionInterval`**
    - URL: https://developer.apple.com/documentation/coregraphics/1408778-cgeventsourcesetlocaleventssuppr
    - Relevance: Disabling the default 250 ms hardware event suppression delay after calling `CGWarpMouseCursorPosition`.
19. **Apple Developer Documentation — `AXIsProcessTrustedWithOptions`**
    - URL: https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions
    - Relevance: Verifying and prompting for macOS TCC Accessibility permissions required for active `CGEventTap` filtering.
20. **Apple Technical Note TN2150 — Using Secure Event Input Fairly**
    - URL: https://developer.apple.com/library/archive/technotes/tn2150/_index.html
    - Relevance: Detecting `IsSecureEventInputEnabled()` when a macOS password field blocks third-party keyboard event taps.
21. **Apple Developer Forums — CoreBluetooth `0x1812` HID Service Restriction**
    - URL: https://developer.apple.com/forums/thread/65807
    - Relevance: Documents why macOS apps cannot advertise the BLE HID GATT service (`0x1812`) via `CBPeripheralManager`.

---

## 4. Open-Source Competitor & Prior-Art Repositories

22. **Genymobile `scrcpy` — `UhidManager.java`**
    - URL: https://github.com/Genymobile/scrcpy/blob/master/server/src/main/java/com/genymobile/scrcpy/uhid/UhidManager.java
    - Relevance: Reference implementation for opening `/dev/uhid` via `android.system.Os` inside an ADB `app_process` server (`uid=2000`).
23. **Genymobile `scrcpy` — `aoa_hid.c`**
    - URL: https://github.com/Genymobile/scrcpy/blob/master/app/src/usb/aoa_hid.c
    - Relevance: Reference implementation for USB AOAv2 HID control transfers (`scrcpy --otg`).
24. **Deskflow — `OSXScreen.mm`**
    - URL: https://github.com/deskflow/deskflow/blob/master/src/lib/platform/OSXScreen.mm
    - Relevance: Reference implementation for macOS Quartz event taps, cursor decoupling, and background cursor hiding via `CGSSetConnectionProperty(..., "SetsCursorInBackground", kCFBooleanTrue)`.
25. **Input Leap Repository**
    - URL: https://github.com/input-leap/input-leap
    - Relevance: Cross-platform software KVM architecture and wire protocol (`ProtocolTypes.h`).
26. **KDE Connect Android — `MouseReceiverService.java` & `SslHelper.java`**
    - URL: https://github.com/KDE/kdeconnect-android
    - Relevance: Illustrates the limitations of `AccessibilityService.dispatchGesture()` for remote input and provides a reference for TOFU mTLS device certificate pinning.
27. **Noise Protocol Framework Specification**
    - URL: https://noiseprotocol.org/noise.html
    - Relevance: Lightweight mutual authentication and ChaCha20-Poly1305 session encryption for SEAM's unified USB and Wi-Fi transport layer.

---

## 5. Dual-Transport, ADB Protocol & Wireless Debugging Specifications

28. **AOSP ADB Protocol Specification (`packages/modules/adb/protocol.txt` & `SERVICES.TXT`)**
    - URL: https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/protocol.txt
    - Relevance: Defines the `127.0.0.1:5037` ADB host protocol, `host:track-devices-l` real-time USB/Wi-Fi device discovery stream, and `forward:tcp:<port>;localabstract:<name>` multiplexing.
29. **AOSP Wireless Debugging Daemon (`packages/modules/adb/daemon/adb_wifi.cpp`)**
    - URL: https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/daemon/adb_wifi.cpp
    - Relevance: Implementation of Android 11–15 Wireless Debugging TLS server, `_adb-tls-connect._tcp` mDNS broadcast, and `/data/misc/adb/adb_temp_keys.xml` key persistence.
30. **AOSP ADB Wireless Pairing Auth (`packages/modules/adb/pairing_auth/`)**
    - URL: https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/pairing_auth/
    - Relevance: SPAKE2+ password-authenticated key exchange used by `_adb-tls-pairing._tcp` (6-digit pairing code and `WIFI:T:ADB;S:...;P:...;;` QR code pairing).
31. **Android Developer Documentation — Wireless Debugging (Android 11+)**
    - URL: https://developer.android.com/tools/adb#wireless-android11-command-line
    - Relevance: Official reference for wireless pairing and TLS ADB connection lifecycle.
32. **Apple Developer Documentation — `Network.framework` (`NWBrowser` & `NWConnection`)**
    - URL: https://developer.apple.com/documentation/network/nwbrowser
    - Relevance: Native macOS mDNS/Bonjour service discovery for `_seam._tcp.local.`, `_adb-tls-connect._tcp.local.`, and `_adb-tls-pairing._tcp.local.`.
33. **Android `LocalSocket.getPeerCredentials()` (`SO_PEERCRED`)**
    - URL: https://developer.android.com/reference/android/net/LocalSocket#getPeerCredentials()
    - Relevance: Kernel-enforced UID verification on `LocalServerSocket("seam_uhid")` ensuring only `uid=2000 (shell)` (`adbd`) can connect to the local USB socket endpoint on Android.
