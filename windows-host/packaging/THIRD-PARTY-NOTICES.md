# Third-party notices — SEAM for Windows (x64)

This file ships inside `SEAM-Windows-x64.zip` and describes exactly what is redistributed
in that archive and what is deliberately left out.

## 1. SEAM itself — MIT

```
SEAM — MIT License
Copyright (c) 2026 Feranmi Oresajo
```

Full text in `LICENSE`, which is included in the ZIP unchanged.

## 2. `seam-agent.jar` — included (first-party build)

The Android agent JAR in this ZIP is **compiled from this repository's own sources**
(`android-agent/src/main/java/com/seam/agent/**`, MIT, same copyright as SEAM) by the
`Windows build` workflow: `javac --release 17` against `platforms/android-35/android.jar`,
then `d8 --min-api 30`. It is the same build `scripts/build-agent.sh` produces on macOS.

- Not a Google binary. Not an APK. Contains only SEAM classes compiled to DEX.
- It is embedded in the same way the macOS app bundle embeds it
  (`scripts/build-host.sh` copies it into `SEAM.app/Contents/Resources/`).
- `BUILD-INFO.txt` in the ZIP records the commit it was built from and its SHA-256.

## 3. .NET 8 runtime — included (self-contained single-file)

`seam-host.exe` is published with `-r win-x64 --self-contained true
-p:PublishSingleFile=true`, so the .NET runtime is embedded inside the executable.
Nothing needs to be installed by the user.

.NET is MIT-licensed and Copyright (c) .NET Foundation and Contributors.
Its full licence text is available at <https://github.com/dotnet/runtime/blob/main/LICENSE.TXT>.
The embedded runtime is an unmodified Microsoft/DotNet Foundation build published on NuGet
(`Microsoft.NETCore.App.Runtime.win-x64`).

## 4. Android `adb` / Platform-Tools — NOT included (by default)

`adb.exe`, `AdbWinApi.dll` and `AdbWinUsbApi.dll` are Google/AOSP Android Platform-Tools.

- **Default build:** excluded. The ZIP ships `Get-Adb.ps1`, which downloads Google's
  official `platform-tools-latest-windows.zip` and unpacks it next to `seam-host.exe`.
  The download is the user's action, under Google's terms
  (<https://developer.android.com/studio/terms>), which is why SEAM does not redistribute it.
- **Opt-in build:** dispatching the `Windows build` workflow with `bundle_adb = true`
  copies the runner's Platform-Tools into `platform-tools/` and appends the notice below.
  The maintainer is responsible for confirming that this redistribution is acceptable
  before shipping such a ZIP publicly.

If Platform-Tools are included, this notice applies:

```
Android SDK Platform-Tools (adb)
Copyright (C) 2007-2024 The Android Open Source Project

Licensed under the Apache License, Version 2.0 (the "License");
you may not use these files except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.
```

## 5. Nothing else

No accounts, no telemetry, no analytics SDKs, no third-party NuGet packages
(`Seam.WindowsHost.csproj` has zero `PackageReference` entries), no network calls other
than to the phone you point it at.
