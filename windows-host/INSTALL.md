# Installing SEAM on Windows

SEAM for Windows ships in two forms, built from the same folder:

| You want | Download | What it does |
|---|---|---|
| The normal install | `SEAM-Setup-x64.exe` | Installs to `C:\Program Files\SEAM`, adds Start Menu shortcuts, registers in **Installed apps**, ships an uninstaller |
| No installation | `SEAM-Windows-x64.zip` | Unzip anywhere and run `seam-host.exe`; moving the folder is fine |

Both contain the same files: the self-contained host (`seam-host.exe` plus the .NET 8
runtime DLLs), `seam-agent.jar`, `platform-tools\adb.exe`, and the documentation below.
**You never need to install .NET, edit `PATH`, or copy anything into `%TEMP%`.**

---

## Install with the installer

1. Run `SEAM-Setup-x64.exe`. Windows SmartScreen will warn you because the build is not
   code-signed: **More info → Run anyway**.
2. Accept the default `C:\Program Files\SEAM`, or choose another folder (paths with spaces are
   fine). A desktop shortcut is optional.
3. Start **SEAM** from the Start Menu.
4. Prepare your phone once (**USB debugging**, see below), then accept the
   *"Allow USB debugging?"* prompt that appears on the phone.

Nothing else is required. Verify the install at any time:

```
"C:\Program Files\SEAM\seam-host.exe" --diagnose
```

### What the installer touches

| Location | What |
|---|---|
| `C:\Program Files\SEAM` | The application and all bundled resources |
| Start Menu → `SEAM` | Launch, `SEAM diagnostics`, `SEAM quick start`, `Uninstall SEAM` |
| `Desktop\SEAM.lnk` | Only if you ticked the box |
| `HKLM\...\CurrentVersion\Uninstall\SEAM_is1` | The **Installed apps** entry |
| `%USERPROFILE%\.seam\auth_key` | Created by the *application* on first run — not by the installer |

### Upgrading

Run a newer `SEAM-Setup-x64.exe`. It reuses the existing folder and replaces the program
files; `%USERPROFILE%\.seam\auth_key` is untouched, so the pairing with your phone survives.

### Uninstalling

**Settings → Apps → Installed apps → SEAM → Uninstall**, or Start Menu → *Uninstall SEAM*.

The program folder and the *Installed apps* entry are removed. Your pairing key at
`%USERPROFILE%\.seam\auth_key` is **kept**: the uninstaller offers to delete it and the
default answer is **No**. Silent uninstalls (`/VERYSILENT`) never delete it. Delete the file
manually if you want it gone.

---

## Portable ZIP

1. Right-click the ZIP → **Extract All**. Explorer creates one folder named
   `SEAM-Windows-x64` with `seam-host.exe` directly inside it (the archive is flat on
   purpose — there is no nested folder).
2. Keep the files together. You may move or rename the folder, including to a path with
   spaces; `seam-host.exe` finds `platform-tools\` and `seam-agent.jar` in **its own folder**.
3. Delete the folder to "uninstall". Your pairing key stays in `%USERPROFILE%\.seam\`.

A USB stick works, but SEAM writes to the phone (pushes the agent), so plug the stick into
a machine you trust.

---

## Phone preparation (once)

1. **Settings → About phone** → tap **Build number** seven times to unlock Developer options.
2. **Settings → Developer options → USB debugging** → on.
3. Plug the phone in and **accept the prompt on the phone** (tick *Always allow from this
   computer* if you trust the PC).

Wireless Debugging (**Developer options → Wireless debugging**) is an alternative when the USB
driver will not cooperate. Android requires one authorised pairing with a code the phone displays,
so pair once with the bundled adb (`MANUAL-VERIFICATION.md` §2.7); after that SEAM finds the phone
on the network by itself (`adb mdns services`), connects it and reconnects when Wi-Fi drops. No
command prompt is needed for routine reconnection.

---

## Troubleshooting

**Setup stops with "DeleteFile failed; code 5. Access is denied." on
`platform-tools\adb.exe`.** Windows will not replace a running program, and the adb server
SEAM starts keeps that exact file open even after the SEAM window is closed. Close SEAM, then
in an Administrator Command Prompt:

```
"C:\Program Files\SEAM\platform-tools\adb.exe" kill-server
```

Re-run Setup. If it still refuses, reboot and install before starting SEAM. Setup now stops
the adb server itself before copying files and schedules any file that is still locked for
replacement at the next restart, so an upgrade should not hit this.

Start here — it prints what was found and where:

```
seam-host.exe --diagnose
```

| Symptom | Meaning | Fix |
|---|---|---|
| `[FATAL] adb.exe was not found ...` | `platform-tools\adb.exe` is missing from the install folder | Reinstall SEAM, or run `Get-Adb.ps1` in the install folder |
| `[FATAL] seam-agent.jar was not found next to the application` | The agent jar was moved or deleted | Reinstall SEAM, or pass `--jar <path>` |
| `adb` sees nothing, phone says nothing | Driver or cable | Try another cable/port; install your vendor's USB driver; or use Wireless Debugging |
| Device shows `state=unauthorized` | The phone has not accepted this PC | Unlock the phone, accept *Allow USB debugging?*, then `adb kill-server` |
| Device shows `state=offline` | Stale ADB session | Unplug/replug, or `platform-tools\adb.exe kill-server` |
| Several devices listed | SEAM refuses to guess | Pick one with `--device <serial>` |
| `--self-test` fails | The build itself is broken | Report the output in an issue |
| Antivirus/SmartScreen blocks the installer | Unsigned build | *More info → Run anyway*, or use the portable ZIP |

`Get-Adb.ps1` is a **repair** tool now, not a prerequisite: it re-downloads Google's official
Platform-Tools into `platform-tools\` if the bundled copy is missing or corrupt.

---

## For maintainers

```
# from the repository root, on Windows
dotnet publish windows-host/Seam.WindowsHost.csproj -c Release -r win-x64 `
  --self-contained true -p:PublishSingleFile=false -o build\app
# (CI then adds seam-agent.jar + platform-tools\ + docs to build\app)

iscc /DAppVersion=0.9.0 /DSourceDir=%CD%\build\app /Obuild\installer windows-host\installer\SEAM.iss
```

`build\app` is the single source of truth: the ZIP is `Compress-Archive` of its contents and
`SEAM.iss` packages the same folder, so the two artifacts cannot drift. See
`.github/workflows/windows-build.yml` for the full sequence, including the silent
install → upgrade → uninstall test.
