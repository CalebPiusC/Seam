SEAM for Windows - x64 build
============================

SEAM shares one mouse and keyboard between this PC and an Android phone.
This build needs no .NET installation, no PATH edits and nothing copied to %TEMP%.

IF YOU USED SEAM-Setup-x64.exe
------------------------------
SEAM is installed in C:\Program Files\SEAM. Start it from the Start Menu ("SEAM") or
from the desktop shortcut if you asked for one: the SEAM window opens. There is no
command to type and no console window.

  - "SEAM"                the application
  - "SEAM diagnostics"    the troubleshooting report, in a console window
  - "SEAM quick start"    this file
  - Uninstall: Settings -> Apps -> Installed apps -> SEAM

Uninstalling keeps your pairing key unless you say otherwise (see YOUR DATA below).

IF YOU USED THE PORTABLE ZIP
----------------------------
The ZIP is flat: Explorer's "Extract All" creates one SEAM-Windows-x64 folder with these
files directly inside it. Keep the folder together - seam-host.exe needs the same
folder's platform-tools\ and seam-agent.jar. You can move the folder anywhere (including
a path with spaces), then double-click seam-host.exe: the SEAM window opens.

WHEN WINDOWS WARNS ABOUT THE APPLICATION (ONCE)
-----------------------------------------------
The SEAM builds are not code-signed. The first time you run SEAM-Setup-x64.exe, or the
first time you run a seam-host.exe that came out of a downloaded ZIP, Windows may show
"Windows protected your PC" (SmartScreen):

  1. Click "More info".
  2. Click "Run anyway".

Windows remembers the choice for that file, so this happens once. It is the only warning
SEAM triggers: the application itself never asks for administrator rights (the installer
does, because it writes to Program Files and registers in Installed apps).

WHAT IS IN THE FOLDER
---------------------
  seam-host.exe              The SEAM desktop application (no console window)
  seam-host.dll, *.dll,      The self-contained .NET 8 desktop runtime.
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

USING THE APPLICATION
---------------------
  1. Enable Developer options -> USB debugging on the phone (tap "Build number"
     seven times in Settings -> About phone to unlock Developer options).
  2. Plug the phone in and tap ALLOW on the "Allow USB debugging?" prompt.
  3. Open SEAM. The window says "No phone detected" until a phone is visible; it does
     not need a phone to start.
  4. Press Connect. SEAM pushes and starts the agent, then authenticates with mutual
     HMAC-SHA256. The status pill turns green: Connected.
  5. Input sharing is enabled automatically after connecting. Move the pointer to the
     screen edge named in the window (right by default) to take control of the phone.
  6. Ctrl + Alt + Q returns control to Windows at any time. Disconnect (or unplug the
     cable) returns control as well.
  7. Unplug and re-plug: SEAM notices the phone again, and the Connect button becomes
     Reconnect. Settings lets you turn on "connect automatically".

Settings live in %APPDATA%\SEAM\ui-settings.json (edge, auto-connect, activity length).
Nothing there is secret.

IF SOMETHING DOES NOT WORK
--------------------------
The window shows inline messages for the three cases that actually happen:

  Unauthorized      Unlock the phone and tap ALLOW. No prompt? Run
                    "adb kill-server" then re-plug the cable.
  Connection error  Read the message; the Diagnostics button shows every path SEAM
                    searched and what adb reports.
  No phone detected Check the cable and the OEM USB driver, or use Wireless debugging
                    (no driver needed).

"SEAM diagnostics" (Start Menu) or this console command prints the same report:

    seam-host.exe --diagnose

It ends with "RESULT: all bundled resources found." when the installation is intact.
It never prints your pairing key - only a short SHA-256 fingerprint.

The original command-line modes are still there for troubleshooting:

    seam-host.exe --self-test        offline protocol/self-check, no phone needed
    seam-host.exe --trajectory       connect and stream a scripted mouse path
    seam-host.exe --capture          console mode: old-style interactive session
    seam-host.exe --help             every option

YOUR DATA
---------
The pairing key lives at %USERPROFILE%\.seam\auth_key (outside the install folder) and
is shared with SEAM on macOS. Upgrades never touch it; uninstalling asks before deleting
it and keeps it by default.

REQUIREMENTS
------------
  Windows 10 (22H2 or later) or Windows 11, 64-bit. One monitor for the first test.
  Android 11+ phone with USB or Wireless Debugging enabled.
  No .NET installation of any kind.

WARNING
-------
While input is being shared, SEAM installs system-wide low-level mouse and keyboard
hooks and swallows input for the phone. Ctrl+Alt+Q always returns control. Do not leave
a shared session unattended. UAC prompts and the lock screen are invisible to low-level
hooks - input pauses there by design.

WHAT IS NOT IMPLEMENTED
-----------------------
Screen mirroring, QR-code pairing and remote control of the phone's screen. SEAM shares
one mouse and one keyboard with the phone's existing Android UI; it does not stream
video. There is no system-tray icon: closing the window ends the session and removes the
hooks, by design.
