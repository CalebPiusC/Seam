SEAM for Windows — x64 portable build
=====================================

This folder is SEAM's Windows host, packaged as a self-contained .NET 8 build.
You do NOT need to install .NET, the .NET SDK, or Visual Studio.

CONTENTS
--------
  seam-host.exe              The SEAM Windows host (self-contained, single file)
  seam-agent.jar             The Android agent, built from this repository's
                             android-agent/ sources (MIT). Pushed to the phone
                             automatically over ADB.
  Get-Adb.ps1                One-command helper that installs Android Platform-Tools
                             (provides adb.exe) next to seam-host.exe.
  ADD-ADB-HERE.txt           Explains the adb requirement (see below).
  LICENSE                    SEAM's MIT licence.
  THIRD-PARTY-NOTICES.md     What is bundled, what is not, and why.
  BUILD-INFO.txt             Exact commit / runner / SDK versions used to build this ZIP.

BEFORE YOU CAN TALK TO A PHONE: adb.exe
---------------------------------------
SEAM talks to the phone through Android's adb (Android Debug Bridge). adb is a
Google/AOSP tool, NOT part of SEAM, and it is deliberately NOT bundled in this ZIP
(the reason is a licensing one and is explained in THIRD-PARTY-NOTICES.md).

Pick one of these — the first is the normal path:

  1. Run the helper (downloads Google's official Platform-Tools into this folder):

         powershell -ExecutionPolicy Bypass -File .\Get-Adb.ps1

     Then adb.exe lives in .\platform-tools\adb.exe and seam-host finds it
     automatically. Nothing else to configure.

  2. You already have adb: leave it on your PATH, or pass --adb <path>.

  3. You do not want adb at all: use Wireless Debugging or a direct TCP connect
     (`seam-host.exe --connect <phone-ip>:27186`) after starting the agent on the
     phone yourself (see the repo README, "Android Setup").

If seam-host.exe reports something like
    Failed to start 'adb.exe'
then adb is simply not findable and step 1 has not been done yet.

PHONE PREPARATION (once)
------------------------
  1. Settings -> About phone -> tap "Build number" 7x to unlock Developer options.
  2. Settings -> Developer options -> enable "USB debugging".
  3. Plug the phone in and ACCEPT the "Allow USB debugging?" prompt on the phone.

Windows needs an OEM ADB driver for most phones; many vendors (e.g. Transsion /
TECNO / Infinix) ship none, and the device simply will not appear in `adb devices`.
Wireless Debugging (Developer options -> Wireless debugging -> Pair device with
pairing code) avoids the driver problem entirely.

QUICK START
-----------
  seam-host.exe --self-test
        Offline check: handshake, frame encoding, TCP loopback round-trip.
        No phone and no adb needed. Expect "0 failed" and exit code 0.

  powershell -ExecutionPolicy Bypass -File .\Get-Adb.ps1     (first time only)

  seam-host.exe --trajectory
        Connects to the real phone, pushes and starts seam-agent.jar, then streams
        a scripted mouse path. If the phone's cursor traces a figure-eight, the
        whole wire path works. Safe: no input hooks, nothing is captured.

  seam-host.exe --capture
        Full control: the mouse routes to the phone on first movement.
        Ctrl+Alt+Q returns control to Windows. Press q in the console to quit.

  seam-host.exe --help
        All options (--edge, --connect, --device, --jar, --adb).

REQUIREMENTS
------------
  Windows 10 22H2 or Windows 11, x64. One monitor for the first test.
  Android 11+ phone with USB or Wireless Debugging enabled.
  No .NET installation of any kind.

WARNING
-------
While routed, seam-host installs system-wide low-level mouse and keyboard hooks and
swallows input for the phone. Ctrl+Alt+Q always returns control. Do not run it while
unattended. UAC prompts and the lock screen are invisible to low-level hooks — input
pauses there by design.
