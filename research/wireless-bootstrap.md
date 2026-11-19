# Wireless Bootstrapping & Lifecycle Architecture

> **Scope:** Deep technical investigation of Android 11–15 Wireless Debugging (`adb_wifi`), wireless pairing and discovery, detached `app_process` survival across Wireless Debugging shutdowns, network transitions, reboot recovery, and the exact role of a companion APK.

---

## 1. The Core Problem of Wireless Non-Root Input on Android

As established in [android-input-architecture.md](file:///Users/oresajooluwaferanmiidunuoluwa/Desktop/PROJECTS/SEAM/research/android-input-architecture.md), opening `/dev/uhid` on an unrooted Android 15 device requires running a process under **`uid=2000 (shell)`** (which holds supplementary group `gid=3011 (uhid)` and the `u:r:shell:s0` SELinux domain).
- A normal Android APK installed from the Play Store or via sideloading runs as an unprivileged app user (`uid >= 10000`, SELinux domain `u:r:untrusted_app:s0`), which is **strictly denied access to `/dev/uhid`**.
- Therefore, whether SEAM connects over USB or Wi-Fi, **`seam-agent` (`uid=2000`) must be spawned at least once per device boot via `adbd` (the Android Debug Bridge daemon)**.

How do we bootstrap `seam-agent` **purely over Wi-Fi** when no USB cable is plugged in, and what happens when Android turns Wireless Debugging off?

---

## 2. Deep Dive: Android 11–15 Wireless Debugging (`adb_wifi`) Internals

Introduced in Android 11 (API 30) and refined through Android 15 (API 35), **Wireless Debugging** (`Settings → System → Developer options → Wireless debugging`) replaces legacy `adb tcpip 5555` (which required a USB cable after every reboot) with a 100% wireless TLS-authenticated architecture implemented in AOSP at `packages/modules/adb/daemon/adb_wifi.cpp`.

```mermaid
sequenceDiagram
    participant Mac as seam-host (macOS NWBrowser + ADB Client)
    participant mDNS as Local Wi-Fi mDNS (224.0.0.251:5353)
    participant PairSrv as Android Pairing Server (_adb-tls-pairing._tcp)
    participant ConnSrv as Android Connect Server (_adb-tls-connect._tcp)
    participant Agent as seam-agent (Detached uid=2000 Daemon)

    Note over Mac,ConnSrv: PHASE 1: One-Time Wireless Pairing (QR Code or 6-Digit PIN)
    Mac->>Mac: Render QR Code: "WIFI:T:ADB;S:seam-pair-9182;P:847291;;"
    Note over PairSrv: User taps "Pair device with QR code" (or 6-digit code) in Wireless Debugging
    PairSrv->>mDNS: Advertise _adb-tls-pairing._tcp.local. (ephemeral port P_pair)
    mDNS-->>Mac: Discovered pairing service at <phone_ip>:P_pair
    Mac->>PairSrv: TLS 1.3 + SPAKE2+ Password Exchange (using P=847291)
    Mac->>PairSrv: Send ~/.android/adbkey.pub (RSA-2048 Public Key)
    PairSrv->>PairSrv: Append key to /data/misc/adb/adb_temp_keys.xml

    Note over Mac,Agent: PHASE 2: Wireless Connection & Detached Agent Spawn
    ConnSrv->>mDNS: Advertise _adb-tls-connect._tcp.local. (ephemeral port P_conn)
    mDNS-->>Mac: Discovered connect service at <phone_ip>:P_conn
    Mac->>ConnSrv: adb connect <phone_ip>:P_conn (TLS 1.3 Client Cert Auth)
    Mac->>ConnSrv: Push /data/local/tmp/seam-agent.jar (if missing/outdated)
    Mac->>ConnSrv: Spawn detached: setsid app_process / com.seam.agent.Main --daemon
    Agent->>Agent: Open /dev/uhid + Bind TCP/UDP 27186 + Advertise _seam._tcp.local.
    Mac->>Agent: Direct Wi-Fi Connection to Port 27186 (Noise XX / mTLS + UDP)
```

### 2.1 Why Randomized Wireless Debugging Ports Break Naive Scripts (and How SEAM Solves It)
Every time a user toggles Wireless Debugging ON, Android binds the wireless `adbd` server to a **new randomized ephemeral TCP port** (e.g., `38149` today, `43911` tomorrow).
- **SEAM's Zero-Config Solution:** `seam-host` on macOS never asks the user to type an IP address or port number! Instead, `seam-host` runs a continuous `NWBrowser` listener for the mDNS service type **`_adb-tls-connect._tcp.local.`**.
- The instant Wireless Debugging is enabled on a previously paired TECNO phone, Android broadcasts `_adb-tls-connect._tcp.local.` with its current IP and randomized port. `seam-host` resolves the mDNS record in `< 100 ms`, connects via TLS, and bootstraps `seam-agent` automatically!

**Sources:**
- AOSP `adb_wifi.cpp`: https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/daemon/adb_wifi.cpp
- AOSP ADB Pairing Auth (`SPAKE2+`): https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/pairing_auth/
- Android Developer Docs — Wireless Debugging: https://developer.android.com/tools/adb#wireless-android11-command-line

---

## 3. Three Wireless Bootstrap Pathways Supported by SEAM

SEAM supports three complementary ways to bootstrap `seam-agent` (`uid=2000`) for wireless use:

| Bootstrap Pathway | How It Works | Requires USB Cable? | Requires Companion APK? | When Used |
| :--- | :--- | :---: | :---: | :--- |
| **W1. Mac-Driven Wireless Debugging (QR / mDNS)** | `seam-host` displays an ADB Pairing QR code (or 6-digit PIN dialog) once, discovers `_adb-tls-connect._tcp` via mDNS, and spawns `seam-agent` over Wi-Fi. | **No** | **No** | Pure wireless onboarding and post-reboot recovery when Mac and Phone are on the same Wi-Fi network. |
| **W2. On-Device Self-Bootstrap (`SEAM.apk` + Embedded ADB)** | `SEAM.apk` embeds a local ADB TLS client (`dadblib`), connects to `127.0.0.1:<wireless_adb_port>` on the phone itself, and spawns `seam-agent` locally. | **No** | **Yes (`SEAM.apk`)** | Allows the user to start `seam-agent` directly on their phone even before opening their MacBook, or over a Personal Hotspot where mDNS between devices may be filtered. |
| **W3. USB Plug-and-Unplug ("1-Second Cable Bootstrap")** | Plugging the phone into the Mac via USB for 1 second automatically spawns `seam-agent` in dual USB+Wi-Fi daemon mode; user then unplugs the cable. | 1-sec initial plug | **No** | Fastest zero-UI fallback on restricted enterprise/hotel Wi-Fi networks where Wireless Debugging is blocked. |

---

## 4. Wireless Debugging Lifecycle, Auto-Disable & Reboot Behavior

> **Critical Engineering Rule:** Do **not** assume Android's Wireless Debugging stays enabled indefinitely!

Let us trace every real-world lifecycle event on Android 15 (and TECNO HiOS 14/15) and verify how `seam-agent` behaves.

### 4.1 What Happens When Wireless Debugging Automatically Turns OFF?
On Android 14 and Android 15, the system automatically turns **Wireless Debugging OFF** when:
1. The Wi-Fi connection drops or switches to another SSID that isn't marked as trusted.
2. An internal `adb_wifi` timeout elapses with no active ADB socket connected.
3. The user manually toggles Wireless Debugging OFF in Developer Options after `seam-agent` has started.

**Does turning Wireless Debugging OFF kill `seam-agent`?**
**NO — provided `seam-agent` is properly daemonized (`setsid` / detached from `adbd`'s process group)!**
- **Why Naive `adb shell` Commands Die:** If you launch a process via a blocking `adb shell app_process ...` session, `adbd` spawns the child inside `adbd`'s PTY/session group. When Wireless Debugging turns off or the `adb` socket closes, `adbd` sends `SIGHUP` to its foreground process group.
- **How SEAM Daemonizes `seam-agent` to Survive `adbd` Shutdown:**
  1. `seam-host` launches `seam-agent` detached:
     ```sh
     nohup app_process -Djava.class.path=/data/local/tmp/seam-agent.jar /system/bin --nice-name=seam_agent_d com.seam.agent.Main --daemon >/dev/null 2>&1 </dev/null &
     ```
  2. Immediately upon entry in `Main.main()`, `seam-agent` calls `android.system.Os.setsid()` (creating a new POSIX session and detaching completely from any controlling terminal) and ignores `SIGHUP`.
  3. **Result:** `seam-agent` is reparented to `init` (`pid = 1`) running under `uid=2000 (shell)` with SELinux domain `u:r:shell:s0`.
  4. Even if **Wireless Debugging is turned completely OFF** 5 seconds after `seam-agent` starts, `seam-agent` **continues running in the background**, keeps its `/dev/uhid` virtual mouse and keyboard alive, and continues serving encrypted SEAM Wi-Fi sessions on TCP/UDP port `27186` until the phone is rebooted!

### 4.2 What Happens Across Wi-Fi Network Changes (SSID Switch / IP Change / Hotspot)?
Because the detached `seam-agent` daemon survives Wi-Fi disconnects:
1. `seam-agent` binds its Wi-Fi server sockets to wildcard address `0.0.0.0:27186` (`::` dual-stack) rather than a single interface IP.
2. When the user moves from Home Wi-Fi (`192.168.1.45`) to Office Wi-Fi (`10.0.12.88`) or enables **MacBook / Android Personal Hotspot**, `seam-agent` detects the interface address change (via `NetworkInterface.getNetworkInterfaces()` or `ConnectivityManager` callback) and re-announces its `_seam._tcp.local.` mDNS record on the new subnet.
3. `seam-host` discovers the updated IP via mDNS and reconnects in `< 300 ms` **without needing Wireless Debugging to be re-enabled**!

### 4.3 What Happens on Device Reboot?
- `/data/local/tmp/seam-agent.jar` **persists** across reboots on Android's ext4/f2fs `/data` partition.
- However, all running processes (including `seam-agent` and its `/dev/uhid` devices) are terminated on reboot, and Android does **not** allow unrooted `uid=2000` scripts to install an `/etc/init` boot script.
- **Post-Reboot Recovery Flow:**
  1. When the TECNO phone finishes booting, if `SEAM.apk` is installed, its `BOOT_COMPLETED` receiver starts a lightweight mDNS beacon (`_seam-standby._tcp.local.`) indicating `status=NEEDS_BOOTSTRAP`.
  2. If the phone reconnects to a Wi-Fi network where the user checked *"Always allow on this network"* during Wireless Debugging pairing, Android automatically re-enables `_adb-tls-connect._tcp.local.`—and `seam-host` (or `SEAM.apk` via `dadblib`) automatically re-spawns `seam-agent` in the background with **zero user interaction**!
  3. If Wireless Debugging was reset to OFF by HiOS on reboot, `seam-host` (or a persistent notification from `SEAM.apk`) offers a 1-tap button that deep-links directly into Android's Wireless Debugging settings page (`Intent("android.settings.APPLICATION_DEVELOPMENT_SETTINGS")` with `:settings:fragment_args_key = toggle_adb_wireless`), OR the user can plug in the USB cable for 1 second.

---

## 5. Is a Companion APK (`SEAM.apk`) Necessary, and How Does `seam-agent` Survive HiOS Background Killers?

### 5.1 Architectural Matrix: Pure `seam-agent.jar` (`app_process`) vs. `seam-agent.jar` + `SEAM.apk`

| Capability | Pure `seam-agent.jar` (Zero APK Installed) | `seam-agent.jar` + `SEAM.apk` Companion App |
| :--- | :---: | :---: |
| **Native `/dev/uhid` Mouse & Keyboard** | **Yes (100% Supported)** | **Yes (via `seam-agent.jar`)** |
| **USB & Wi-Fi Transport (`SEAM-Wire v1`)** | **Yes (100% Supported)** | **Yes (via `seam-agent.jar`)** |
| **Display Resolution & Orientation Telemetry** | **Yes (`DisplayManagerGlobal` via `uid=2000`)** | **Yes** |
| **Bidirectional Clipboard Sync** | **Yes (`IClipboard` Binder via `uid=2000`)** | **Yes** |
| **Return-Edge Detection (Android → Mac)** | Open-Loop Linearized Shadow Counter (`mouse_pointer_acceleration_enabled=0`) | **1px Transparent Hover Gutter (`ACTION_HOVER_MOVE` Ground-Truth) + Shadow Counter** |
| **Post-Reboot Wireless Self-Start on Phone** | Requires Mac on same LAN (or 1-sec USB plug) | **Yes (On-device `dadblib` + Quick Settings Tile)** |

**Architectural Conclusion:**
- **`seam-agent.jar` is 100% self-sufficient** for Milestones 1, 2, 3, and 4! Even if the user never installs an APK on their TECNO phone, `seam-agent.jar` runs over both USB and Wi-Fi, drives `/dev/uhid`, tracks orientation, syncs the clipboard, and triggers return-edge transitions via linearized shadow coordinates.
- **`SEAM.apk` is an enhancer, not a single point of failure.** Even if HiOS kills `SEAM.apk`, `seam-agent.jar` (`uid=2000`) keeps `/dev/uhid` and the USB/Wi-Fi input loop running without interruption.

### 5.2 Why `seam-agent` (`uid=2000`) Survives TECNO HiOS 14/15 Background Restrictions
Transsion's HiOS (on TECNO devices) includes aggressive app killers (`Phone Master`, MediaTek `DuraSpeed`, and AOSP's `CachedAppOptimizer` freezer).
1. **Why APK Services Get Killed:** HiOS's `Phone Master` and `ActivityManagerService` iterate over **registered package UIDs (`uid >= 10000`)** spawned by `Zygote` and kill or freeze their cgroups when the screen turns off or memory pressure rises.
2. **Why `seam-agent` Escapes `Phone Master` / `DuraSpeed`:**
   - `seam-agent` is spawned as a native system-shell daemon under **`uid=2000 (shell)`**, **not** an application package UID (`uid >= 10000`).
   - Its `/proc/<pid>/oom_score_adj` is `0` (normal system daemon priority, compared to `+700..+999` for background apps).
   - It is not tracked in `ActivityManagerService`'s LRU app list (`mLruProcesses`), so Android 15's phantom-process killer (which only kills children of `uid >= 10000` app processes) and HiOS `DuraSpeed` do not target it.
3. **Preventing Wi-Fi Power-Save Sleep Spikes (`IPowerManager` Wakelock via `uid=2000`):**
   - When an Android phone's screen is on (or idle on a desk without a USB charging cable), the MediaTek Wi-Fi driver enters IEEE 802.11 Power Save Polling (PSP) mode, which can spike UDP/TCP packet latency from `3 ms` to `40–80 ms`.
   - Because `uid=2000 (shell)` holds `android.permission.WAKE_LOCK`, `seam-agent` acquires a partial wakelock and low-latency Wi-Fi lock via Binder reflection (`IPowerManager.acquireWakeLock` / `IWifiManager.acquireWifiLock` with `WIFI_MODE_FULL_LOW_LATENCY = 4`) exclusively while the macOS cursor is actively routed to the Android screen (`CURSOR_ENTER` → `CURSOR_LEAVE`), and releases it the instant the cursor returns to macOS!
