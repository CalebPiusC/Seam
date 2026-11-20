SEAM for Windows - x64 build
============================

This is the SEAM Windows host, packaged as a self-contained .NET 8 build.
You do NOT need to install .NET, the .NET SDK, or Visual Studio.
Nothing needs to be added to PATH, and nothing is copied to %TEMP% at run time.

IF YOU USED SEAM-Setup-x64.exe
------------------------------
SEAM is installed under C:\Program Files\SEAM. Start it from the Start Menu
("SEAM"), or from the desktop shortcut if you asked for one. Uninstall it from
Settings -> Apps -> Installed apps -> SEAM. Uninstalling keeps your pairing key
unless you explicitly say otherwise (see "YOUR DATA" below).

IF YOU USED THE PORTABLE ZIP
----------------------------
The ZIP is flat: Windows Explorer's "Extract All" creates a single
SEAM-Windows-x64 folder with these files directly inside it. Keep the whole
folder together - seam-host.exe needs the same folder's platform-tools\ and
seam-agent.jar. You can move the folder anywhere (including a path with spaces);
you can run seam-host.exe from Explorer, a shortcut, PowerShell, or cmd.exe.

CONTENTS
--------
  seam-host.exe              The SEAM Windows host
  seam-host.dll, *.dll,      The self-contained .NET 8 runtime and SEAM code.
  hostfxr.dll, hostpolicy.dll,   These stay in the same folder as seam-host.exe.
  coreclr.dll, System.*.dll
  seam-agent.jar             The Android agent, built from this repository's
                             android-agent/ sources (MIT). Pushed to the phone
                             automatically over ADB. Never edit or move it.
  platform-tools\            Android Platform-Tools: adb.exe + its two DLLs.
                             Used automatically from this folder.
  Get-Adb.ps1                Optional repair tool: re-downloads Google's official
                             Platform-Tools if platform-tools\ is missing/corrupt.
  LICENSE                    SEAM's MIT licence.
  THIRD-PARTY-NOTICES.md     What is bundled, what is not, and why.
  BUILD-INFO.txt             Exact commit / runner / SDK versions used to build.

HOW SEAM FINDS ITS FILES
------------------------
SEAM looks next to seam-host.exe, never in the current directory, on PATH, or in
%TEMP%:

  adb.exe       platform-tools\adb.exe   (then adb.exe, then PATH / Android SDK;
                                         a bundled copy always wins)
  agent jar     seam-agent.jar           (then Resources\seam-agent.jar)

Override either one explicitly with --adb <path> / --jar <path>.
Run `seam-host.exe --diagnose` to print exactly what was found and where.

PHONE PREPARATION (once)
------------------------
  1. Settings -> About phone -> tap "Build number" 7x to unlock Developer options.
  2. Settings -> Developer options -> enable "USB debugging".
  3. Plug the phone in and ACCEPT the "Allow USB debugging?" prompt on the phone.
     (Tick "Always allow from this computer" if you trust the machine.)

If SEAM says the device is "unauthorized", unlock the phone and accept the prompt.
If it says "offline", unplug/replug the cable or run `adb kill-server`.
If the phone never appears at all, Windows is missing an OEM ADB driver - many
vendors (e.g. Transsion / TECNO / Infinix) ship none. Wireless Debugging avoids
the driver problem entirely.

QUICK START
-----------
  seam-host.exe --diagnose
        Show the app folder, the adb it will use, the agent jar it found, the
        pairing-key fingerprint, and the devices adb can see. Read-only.

  seam-host.exe --self-test
        Offline check: handshake, frame encoding, TCP loopback round-trip and
        resource discovery. No phone and no adb needed.
        Expect "0 failed" and exit code 0.

  seam-host.exe --trajectory
        Connects to the real phone, pushes and starts seam-agent.jar, then streams
        a scripted mouse path. If the phone's cursor traces a figure-eight, the
        whole wire path works. Safe: no input hooks, nothing is captured.

  seam-host.exe --capture
        Full control: the mouse routes to the phone on first movement.
        Ctrl+Alt+Q returns control to Windows. Press q in the console to quit.

  seam-host.exe --help
        All options (--edge, --connect, --device, --jar, --adb).

YOUR DATA
---------
The pairing key lives at %USERPROFILE%\.seam\auth_key (outside the install
folder) and is shared with SEAM on macOS. Upgrades never touch it; uninstalling
asks before deleting it and keeps it by default. SEAM never prints the key -
only a short SHA-256 fingerprint, which is not the key itself.

REQUIREMENTS
------------
  Windows 10 22H2 or Windows 11, x64. One monitor for the first test.
  Android 11+ phone with USB or Wireless Debugging enabled.
  No .NET installation of any kind.

WARNING
-------
While routed, seam-host installs system-wide low-level mouse and keyboard hooks
and swallows input for the phone. Ctrl+Alt+Q always returns control. Do not run
it while unattended. UAC prompts and the lock screen are invisible to low-level
hooks - input pauses there by design.

WHAT IS NOT DONE YET
--------------------
Screen mirroring, QR-code pairing and remote control of the phone screen are NOT
implemented. SEAM shares one mouse and one keyboard with the phone's existing
Android UI; it does not stream video. See the repository README for the current
status.
