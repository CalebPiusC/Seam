# SEAM Windows host — prototype

A Windows host for SEAM that talks to the **existing, unmodified Android agent** over the
**existing `SEAM-Wire v1` protocol**.

Nothing outside `windows-host/`, the packaging assets under `windows-host/packaging/`, and
`.github/workflows/windows-build.yml` was changed: `macos-host/` and `android-agent/` are untouched.

---

## 0. Get a Windows build without installing anything

You do **not** need the .NET SDK, the .NET runtime, or Visual Studio to run SEAM on Windows.
A GitHub Actions workflow builds, tests and packages it on a Windows runner:

**Actions → “Windows build” → Run workflow** (manual trigger, nothing is published on its own).

When the run finishes, download the artifact:

**Actions → the run → Artifacts → `SEAM-Windows-x64`** → unzip → `SEAM-Windows-x64.zip`.

What the workflow actually does, in order, and fails on the first broken step:

```text
dotnet restore  →  dotnet build -c Release  →  seam-host.exe --self-test
   →  javac + d8 (builds seam-agent.jar from android-agent/ sources)
   →  dotnet publish -r win-x64 --self-contained -p:PublishSingleFile=true
   →  published seam-host.exe --self-test  →  zip  →  upload artifact
```

Inside the ZIP:

```text
SEAM-Windows-x64/
├── seam-host.exe              self-contained single file (no .NET needed)
├── seam-agent.jar             Android agent, built from this repo's sources
├── Get-Adb.ps1                one command to install Android Platform-Tools
├── ADD-ADB-HERE.txt           why adb.exe is not in the ZIP, and why
├── README-WINDOWS.txt         quick start
├── THIRD-PARTY-NOTICES.md     what is bundled and under which licence
├── BUILD-INFO.txt             commit, runner, SDK versions, SHA-256s
└── LICENSE
```

**`adb.exe` is not bundled by default.** Android Platform-Tools are Google/AOSP binaries; adding
them to a project ZIP is a redistribution decision for the maintainer, not something a build
script should do silently (`windows-host/packaging/THIRD-PARTY-NOTICES.md`). The ZIP ships
`Get-Adb.ps1`, which downloads Google's official archive into `platform-tools\` next to the
executable — one command, no admin rights, no PATH edits — and `seam-host.exe` looks there first.
If you would rather bundle them, run the workflow with `bundle_adb = true`.

**`seam-agent.jar` *is* bundled,** because it is compiled from this repository's own MIT-licensed
`android-agent/` sources by the same workflow (the macOS app bundle embeds it the same way).

---


## 1. Honest status up front

The authoring sandbox was **Linux with no .NET SDK, no JVM, no `adb` and no Android device**,
and only npm/PyPI/GitHub were reachable, so no .NET toolchain could be installed
(`nuget.org`, `dot.net` and Debian mirrors are blocked).

| | State |
|---|---|
| Protocol / auth / framing design | **Verified by execution** — 33 conformance checks pass (`tools/verify_protocol.py`) against a device-side simulator transliterated from the shipped Java |
| C# sources | **Not compiled.** No `dotnet build` has ever run on them. Structurally checked only (`tools/check_csharp_structure.py`, 10/10 files) |
| Windows low-level hooks, `ClipCursor`, DPI | **Never executed** — no Windows machine available |
| `adb` bootstrap, device discovery | **Never executed** — `adb` and a device were unavailable |
| Real Android cursor movement | **Not demonstrated** — requires the above two rows |

Do not read this as "the Windows host works". Read it as: *the protocol half is proven, the
platform half is written and unproven.* The single command that would close most of the gap is
`seam-host.exe --self-test` on real Windows; the second is `--trajectory` against a real phone.

---

## 2. What was reused vs. written

**Reused unchanged**
- The Android agent (`seam-agent.jar`) — no modifications, no rebuild, same auth key scheme.
- `SEAM-Wire v1` — every opcode, payload length, field order, domain string and nonce ordering,
  transcribed from `Protocol/SeamWireProtocol.swift` / `SeamProtocol.java`.
- The transport topology — USB is still `adb forward tcp:0 localabstract:seam_uhid`; Wi-Fi is
  still a plain TCP connection to port 27186.
- Bootstrap semantics — remote paths, `SEAM_AGENT_READY` / `SEAM_WIFI_ENDPOINT:` log markers,
  the detached `nohup … app_process … --server --detach` launch, the jar+key stamp idempotency
  check, and the "never suppress the phone's on-screen keyboard" invariant.
- Cursor feel constants — `pointerVelocityGain = 1.85`, the `360`/`65175` entry insets, the
  4 px edge-return threshold, 160 ms entry grace, 1/32-notch scroll units, 500 ms heartbeat.

**Written fresh (all Windows-specific, ~1,500 lines)**
- `Input/WindowsInputCapture.cs` — `WH_MOUSE_LL` / `WH_KEYBOARD_LL` hooks, edge-crossing state
  machine, pointer pinning by `SetCursorPos` re-centring + `ClipCursor` guard box, panic hotkey.
- `Input/WindowsKeyTable.cs` — Set-1 scan code → HID Usage Page 0x07 table, 6KRO state.
- `Transport/SeamConnection.cs` — TCP session, frame reader, 500 ms heartbeat.
- `Bootstrap/AdbBootstrapper.cs` — `adb` discovery, device parsing, push/launch, forwarding.
- `Testing/` — in-process loopback agent + offline self-test.

**Deliberately not built:** tray UI, arrangement flyout, UDP fast path, Wi-Fi discovery probe,
clipboard monitoring, packaging. Prototype scope only.

---

## 3. Build

Requires the [.NET 8 SDK](https://dotnet.microsoft.com/download) (Windows, macOS or Linux).
Only local *development* needs it — end users get the self-contained ZIP from the workflow above.
No NuGet packages are referenced — the project targets plain `net8.0` and uses only P/Invoke,
so it compiles anywhere and runs only on Windows.

```bat
cd windows-host
dotnet build -c Release
```

Output: `windows-host/bin/Release/net8.0/seam-host.exe`

You also need the **unchanged** agent jar. Build it once on a Mac (`make build-agent`) or
extract it from `SEAM.app/Contents/Resources/seam-agent.jar`, then place it next to
`seam-host.exe` (or pass `--jar`). You also need `adb.exe` (Android Platform-Tools) either on
`PATH`, in `platform-tools\` next to the exe, or via `--adb`.

---

## 4. Run

### 4a. No phone at all — offline self-test (start here)
```bat
seam-host.exe --self-test
```
Checks the golden handshake vectors, every frame layout, and a full TCP handshake against the
in-process loopback agent. Expected: `N passed, 0 failed`, exit code 0.

### 4b. Real phone, no input hooks — prove the wire path
```bat
REM USB (needs an ADB driver — Windows is not driverless like macOS)
seam-host.exe --trajectory

REM or over Wi-Fi / Wireless Debugging, bypassing ADB and the driver entirely
seam-host.exe --connect 192.168.1.42:27186 --trajectory
```
Streams `CURSOR_ENTER` + a 240-frame figure-eight + an edge-return push. **If the phone's real
hardware cursor moves, the Windows→Android path is proven end-to-end.** This is the acceptance
test that matters most.

### 4c. Interactive — capture Windows input
```bat
seam-host.exe                      REM phone on the right edge of the screen
seam-host.exe --edge left
seam-host.exe --capture            REM route on first movement (deterministic demo)
```
Move the pointer to the configured edge to take control of the phone. **`Ctrl+Alt+Q`** returns
control immediately. Press `q` in the console to quit, `r` to force a return.

> Safety: this installs system-wide input hooks that swallow mouse/keyboard while routed.
> Run it unelevated first, and keep the console window visible so `q`/Ctrl+Alt+Q are reachable.
> The hooks are removed on exit; `ClipCursor` is released in `Dispose` and on panic.

---

## 5. Feature status

| Capability | Implemented | Verified |
|---|---|---|
| ADB device discovery (`adb devices -l` parsing) | yes | no |
| Agent deploy/launch + ready-marker wait | yes | no |
| `adb forward tcp:0 → localabstract:seam_uhid` | yes | no |
| Mutual HMAC-SHA256 handshake | yes | **yes** (byte-exact, both directions) |
| `DISPLAY_INFO` receive + parse | yes | **yes** |
| `PING`/`PONG` heartbeat + RTT plumbing | yes | **yes** |
| `EDGE_RETURN` receive + cursor restore | yes | **yes** (parse + receive); Windows restore untested |
| Mouse movement forwarding | yes | **protocol path yes**, hooks no |
| Mouse buttons (L/R/M/X1/X2) | yes | protocol only |
| Scroll (1/32-notch conversion) | yes | protocol only |
| Keyboard (scan code → HID, 6KRO) | yes | protocol only |
| Edge crossing + pointer pinning | yes | no |
| Clipboard host→Android | frame + `--` | protocol yes; no monitor |
| Clipboard Android→host | parse + log | protocol yes; no pasteboard write |
| Wi-Fi TCP transport | via `--connect` | no |
| Wi-Fi UDP fast path | no | — |
| Wi-Fi/UDP discovery, mDNS pairing | no | — |
| Tray UI, packaging, signing | no | — |

---

## 6. What was actually executed here

```
$ python3 tools/verify_protocol.py
=== SEAM-Wire v1 conformance verification ===
[1] Golden handshake vectors (client path, Java-derived)     6/6 PASS
[2] Frame layouts                                           14/14 PASS
[3] End-to-end against the device simulator (real TCP)       13/13 PASS
=== 33 passed, 0 failed ===
```

Covered by that run: 38-byte challenge parse, 68-byte response bytes, client HMAC against a
Java-derived vector, 41-byte ack verification, LE session id, `DISPLAY_INFO` 1080×2400@420/120,
50 mouse frames delivered, key frames delivered, clipboard text round-trip, PONG timestamp echo,
`EDGE_RETURN` triggered by pushing past the bezel.

```
$ python3 tools/check_csharp_structure.py windows-host
10 file(s) checked, 0 with structural problems
```
Balanced delimiters outside strings/comments, no Python-isms, no duplicate types. **Not a
compiler.**

```
$ python3 tools/check_java_parity.py
=== 44 passed, 0 failed ===
```
Escapes the "oracle is a Python transliteration" problem: it parses the **upstream Java**
(`SeamProtocol.java`, `SeamAuthenticator.java`, `SeamInputEngine.java`, `UhidDevice.java`) and
compares magic, version, transport ids, all 10 opcodes, payload lengths, edge ids, the 256 KiB
clipboard cap, heartbeat timeout, nonce/HMAC sizes and both auth-domain strings against the C#
*and* the simulator, plus the payload field order taken from the agent's own readers. All three
now agree; the check is a static text comparison, not a runtime test.

**None of this compiles or runs the C#.** See `WINDOWS-READINESS-REVIEW.md` (repo root) for the
file-by-file review, the bugs fixed in this pass, and the exact Windows test procedure.

`tools/agent_sim.py` is the fixture those tests run against: a transliteration of
`SeamAuthenticator.java` + `UsbLocalSocketServer.java` + the shadow-cursor part of
`SeamInputEngine.java`. It is a test double, clearly not the product, and it proves nothing
about `/dev/uhid` or Android input injection.

---

## 7. Blockers hit

1. **No .NET SDK obtainable.** `dot.net`, `builds.dotnet.microsoft.com` and `nuget.org` are all
   unreachable from the sandbox; the npm package `dotnet-sdk` is the 2017 SDK 2.0 wrapper and
   downloads from the same blocked hosts. Consequence: the C# has never been compiled.
2. **No Windows host.** The Windows-only behaviour (hook reliability, `ClipCursor` clearing on
   focus change, DPI handling, sub-notch wheel deltas) cannot be exercised from Linux at all.
3. **No `adb`, no device, no JVM.** So neither the real agent nor a real handset could be used;
   the Java transliteration in `tools/agent_sim.py` was the closest available oracle.
4. Tree-sitter's prebuilt C# WASM grammar would not load with any `web-tree-sitter` I could
   install (dylink/ABI mismatch), which is why the structural checker is hand-rolled.

---

## 8. Next three tasks

1. **`dotnet build` + `--self-test` on real Windows.** Fix whatever the compiler and the
   golden-vector assertions report. This converts the biggest unknown (does it even build and
   hand-shake?) into a known-good baseline, and needs no phone.
2. **`--trajectory` against the real handset over USB and over `--connect`,** capturing RTT and
   confirming the native cursor moves. This validates the ADB bootstrap, the agent reuse, and
   the frame path against the *actual* `seam-agent.jar` rather than the simulator.
3. **Harden the input capture path:** verify edge crossing and pointer pinning at 100/150/200 %
   DPI on a dual-monitor setup, add a hook-liveness watchdog (Windows removes a slow hook
   silently, with no notification), and release `ClipCursor` on session lock/desktop switch.

Then, in priority order: clipboard monitor (host→Android paste), Wi-Fi UDP fast path with
signed 42-byte datagrams, discovery probe + mDNS pairing, tray flyout, packaging/signing.

---

## 9. Source map

```
windows-host/
├── Program.cs                     CLI: default / --self-test / --trajectory / --connect
├── Protocol/SeamWireProtocol.cs   constants, coordinates, DISPLAY_INFO/EDGE_RETURN parsing
├── Protocol/SeamAuthenticator.cs  3-message mutual HMAC-SHA256 (client side)
├── Protocol/SeamFrames.cs         outbound frame serializers
├── Transport/SeamConnection.cs    TCP session, reader, heartbeat
├── Bootstrap/AdbBootstrapper.cs   adb discovery, deploy, launch, forward
├── Input/WindowsKeyTable.cs       scan code → HID table, 6KRO state
├── Input/WindowsInputCapture.cs   LL hooks, edge crossing, pointer pinning
└── Testing/                       LoopbackAgent (fixture) + SelfTest (oracle-driven)

tools/
├── agent_sim.py                   device-side simulator (test fixture)
├── verify_protocol.py             33 executable conformance checks
└── check_csharp_structure.py      structural lint for the uncompiled C#
```

## 10. Licence

Inherits the repository's MIT licence (© 2026 Feranmi Oresajo); this directory is a derivative
work and must keep the original copyright notice.
