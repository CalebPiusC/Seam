# Manual verification on real Windows hardware

The CI workflow proves everything that can be proven without a phone: it compiles, runs the
offline self-test, publishes the app folder, resolves resources from a path with spaces,
builds the ZIP and the installer, **silently installs the app, runs it from the install
folder, reinstalls over it, and uninstalls it again**. It cannot prove anything about a
physical phone, a USB driver, or real mouse/keyboard capture.

Run this list on the machine you reported problems from. Every step states the exact command
and the result that counts as a pass. Nothing below has been executed by the agent — this is
the list to execute.

---

## 0. Record what you are testing

```
seam-host.exe --diagnose
```

Paste the whole output into the issue. It contains no key material: the pairing key is
printed as `fingerprint: <16 hex>` only.

Pass: ends with `RESULT: all bundled resources found.` and exit code 0
(`echo $LASTEXITCODE` in PowerShell).

---

## 1. Installer, clean machine

1. No SEAM installed, no `%USERPROFILE%\.seam` folder.
2. Double-click `SEAM-Setup-x64.exe` → SmartScreen → **More info → Run anyway**.
3. Install to the default `C:\Program Files\SEAM`, tick the desktop shortcut.

Pass:
- Start Menu contains `SEAM`, `SEAM diagnostics`, `SEAM quick start`, `Uninstall SEAM`.
- **Settings → Apps → Installed apps** lists `SEAM 0.9.0` with an uninstall entry.
- `C:\Program Files\SEAM\platform-tools\adb.exe` and `C:\Program Files\SEAM\seam-agent.jar`
  exist.

## 2. Shortcut launch resolves resources

Launch **SEAM** from the Start Menu, then from the desktop shortcut, then:

```
cd C:\
& "C:\Program Files\SEAM\seam-host.exe" --diagnose
```

Pass: all three report `app dir : C:\Program Files\SEAM`, `source : bundled with SEAM`, and
`RESULT: all bundled resources found.` — no `%TEMP%` path anywhere, and no PATH dependency.

## 3. Phone authorisation flow

1. Phone connected by USB, USB debugging on, **not yet authorised**.
2. Launch SEAM.

Pass: SEAM reports the device as `unauthorized` and tells you to accept the prompt on the
phone. Accept it, re-run, and the device appears as authorised.

## 4. Agent push and start

1. Phone authorised, no agent running (`adb shell ps | findstr seam` returns nothing).
2. `seam-host.exe --trajectory`

Pass: host pushes `seam-agent.jar` to `/data/local/tmp/seam-agent.jar`, starts it, the
handshake prints `mutual HMAC-SHA256 OK`, `DISPLAY_INFO` is printed, and the phone's cursor
traces a figure-eight. No input hooks are installed in this mode, so your PC mouse keeps
working normally.

Then:

```
adb -s <serial> shell cat /data/local/tmp/seam-agent.log
```

Pass: the log contains `SEAM_AGENT_READY` and **no** `--auth-key` value.

## 5. Full capture mode

`seam-host.exe --capture` — move the mouse right off the screen edge onto the phone.

Pass: the phone cursor moves; `Ctrl+Alt+Q` returns control to Windows; `q` in the console
exits. Confirm the PC keyboard types on the phone and comes back after `Ctrl+Alt+Q`.

Known behaviour, not a bug: input pauses while a UAC prompt or the lock screen is up
(low-level hooks cannot see them).

## 6. Upgrade preserves pairing

1. Note the fingerprint from `--diagnose` (`PAIRING KEY / fingerprint:`).
2. Run `SEAM-Setup-x64.exe` again (same version is fine).

Pass: install completes without an error, `--diagnose` still prints the **same**
fingerprint, `%USERPROFILE%\.seam\auth_key` still exists, and `--trajectory` reconnects
without re-pairing the phone.

## 7. Uninstall keeps user data by default

**Settings → Apps → SEAM → Uninstall.**

Pass: the wizard asks about the pairing key with **No** preselected. Answer **No** →
`C:\Program Files\SEAM` is gone, the Start Menu entries are gone, *Installed apps* no longer
lists SEAM, and `%USERPROFILE%\.seam\auth_key` still exists.

Repeat the install/uninstall once choosing **Yes** → the key file is deleted.

## 8. Portable ZIP

1. Extract `SEAM-Windows-x64.zip` to a folder whose path has spaces, e.g.
   `C:\Users\<you>\Desktop\SEAM test (v2)`.
2. Run `seam-host.exe --self-test`, `--diagnose`, then `--trajectory` from that folder.

Pass: all three work; `app dir` is the spaced folder; `source : bundled with SEAM`.

3. Rename the folder and run again.

Pass: still works — nothing is stored in the folder that would break a move.

Pass: **no** two-nested-folders situation after Explorer's *Extract All*.

## 9. No-tooling check

On a Windows machine with **no** .NET, **no** JDK, **no** Android SDK, and a `PATH` that
contains no adb:

- Installer path and portable path both run `--self-test` and `--diagnose` successfully.
- `where adb` returns "not found", yet `--diagnose` still shows `source : bundled with
  SEAM` and a working `adb version` line.

## 10. macOS and Android untouched

- `macos-host/` build and `scripts/build-agent.sh` behaviour are unchanged by this work
  (no files under `macos-host/` or `android-agent/` were modified).
- The Android agent's wire protocol is version `0x01`, unchanged; the phone does not need a
  new agent build for this Windows release.

---

## Reporting

Open an issue at <https://github.com/CalebPiusC/Seam/issues> with:

1. `--diagnose` output (safe: no key material).
2. The `RESULT:` line and exit code.
3. Phone model, Android version, connection type (USB / Wireless Debugging).
4. Which numbered step above failed and what you saw instead.
