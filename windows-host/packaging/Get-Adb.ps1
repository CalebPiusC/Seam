<#
.SYNOPSIS
    Installs Android Platform-Tools (adb.exe) next to seam-host.exe.

.DESCRIPTION
    SEAM drives the phone through Android's adb. adb is a Google/AOSP tool and is not
    redistributed inside the SEAM Windows ZIP (see THIRD-PARTY-NOTICES.md). This helper
    downloads Google's official Platform-Tools archive *on your behalf* and unpacks it
    into .\platform-tools\, which is where seam-host.exe looks first.

    By running this you download and use Google's Platform-Tools under Google's terms:
    https://developer.android.com/studio/terms

.PARAMETER Force
    Re-download even if .\platform-tools\adb.exe already exists.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Get-Adb.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Get-Adb.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # much faster Invoke-WebRequest on PS 5.1

$url      = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
$destDir  = Join-Path $PSScriptRoot 'platform-tools'
$adbExe   = Join-Path $destDir 'adb.exe'

Write-Host "SEAM: Android Platform-Tools installer" -ForegroundColor Cyan
Write-Host "  target : $destDir"

if ((Test-Path $adbExe) -and -not $Force) {
    Write-Host "  adb.exe already present — nothing to do (use -Force to re-download)." -ForegroundColor Green
    & $adbExe version
    exit 0
}

$tmpDir  = Join-Path ([System.IO.Path]::GetTempPath()) ("seam-adb-" + [guid]::NewGuid().ToString('N'))
$zipPath = Join-Path $tmpDir 'platform-tools.zip'
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

try {
    Write-Host "  source : $url"
    Write-Host "  downloading..."
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing

    $size = (Get-Item $zipPath).Length
    if ($size -lt 1MB) {
        throw "download looks wrong ($size bytes) — no network, or a proxy/captive portal intercepted it"
    }
    Write-Host ("  downloaded {0:N1} MB" -f ($size / 1MB))

    Write-Host "  extracting..."
    Expand-Archive -Path $zipPath -DestinationPath $tmpDir -Force

    $src = Join-Path $tmpDir 'platform-tools'
    if (-not (Test-Path (Join-Path $src 'adb.exe'))) {
        throw "platform-tools\adb.exe missing from the archive — Google may have changed the layout"
    }

    if (Test-Path $destDir) { Remove-Item -Recurse -Force $destDir }
    Move-Item -Path $src -Destination $destDir

    Write-Host ""
    Write-Host "Installed:" -ForegroundColor Green
    & $adbExe version
    Write-Host ""
    Write-Host "Next steps:"
    Write-Host "  1. Enable USB debugging on the phone and plug it in."
    Write-Host "  2. Accept the 'Allow USB debugging?' prompt ON THE PHONE."
    Write-Host "  3. .\seam-host.exe --trajectory"
    Write-Host ""
    Write-Host "If 'adb devices' stays empty, the phone needs an OEM ADB driver."
    Write-Host "Wireless Debugging avoids that entirely: Developer options ->"
    Write-Host "Wireless debugging -> Pair device with pairing code, then:"
    Write-Host "  .\platform-tools\adb.exe pair <ip>:<port>"
    Write-Host "  .\platform-tools\adb.exe connect <ip>:<port>"
}
finally {
    if (Test-Path $tmpDir) { Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue }
}
