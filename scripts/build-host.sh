#!/usr/bin/env bash
# ==============================================================================
# SEAM macOS Host & Native Application Bundle Builder
# Compiles macos-host (Swift 6 -> dist/seam-host) and packages dist/SEAM.app
# with an ad-hoc code signature for macOS TCC Accessibility permissions.
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/SEAM.app"
BIN_OUT="$DIST_DIR/seam-host"

echo "==> [1/2] Compiling SEAM macOS Host (Swift -> arm64 release)..."
cd "$ROOT_DIR/macos-host"
swift build -c release

mkdir -p "$DIST_DIR"
cp "$ROOT_DIR/macos-host/.build/release/seam-host" "$BIN_OUT"

echo "==> [2/2] Packaging native macOS Application Bundle ($APP_BUNDLE)..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_OUT" "$APP_BUNDLE/Contents/MacOS/seam-host"
if [[ -f "$DIST_DIR/seam-agent.jar" ]]; then
    cp "$DIST_DIR/seam-agent.jar" "$APP_BUNDLE/Contents/Resources/seam-agent.jar"
fi

ICON_DOC="$ROOT_DIR/macos-host/Resources/AppIcon.icon"
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
if [[ ! -x "$ICTOOL" ]]; then
    ICTOOL="/Applications/Xcode.app/Contents/Developer/usr/bin/ictool"
fi
if [[ -d "$ICON_DOC" && -x "$ICTOOL" ]]; then
    echo "    Rendering AppIcon from Icon Composer ($ICON_DOC)..."
    ICONSET_DIR="$ROOT_DIR/build/AppIcon.iconset"
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR" "$ROOT_DIR/build"
    for spec in \
        "16 1 icon_16x16.png" \
        "16 2 icon_16x16@2x.png" \
        "32 1 icon_32x32.png" \
        "32 2 icon_32x32@2x.png" \
        "128 1 icon_128x128.png" \
        "128 2 icon_128x128@2x.png" \
        "256 1 icon_256x256.png" \
        "256 2 icon_256x256@2x.png" \
        "512 1 icon_512x512.png" \
        "512 2 icon_512x512@2x.png"
    do
        read -r w s fname <<< "$spec"
        "$ICTOOL" "$ICON_DOC" \
            --export-image \
            --output-file "$ICONSET_DIR/$fname" \
            --platform macOS \
            --rendition Default \
            --width "$w" \
            --height "$w" \
            --scale "$s" >/dev/null
    done
    iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET_DIR"

    if [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/actool" ]]; then
        DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
            /Applications/Xcode.app/Contents/Developer/usr/bin/actool \
            "$ICON_DOC" \
            --compile "$APP_BUNDLE/Contents/Resources" \
            --platform macosx \
            --minimum-deployment-target 14.0 \
            --app-icon AppIcon \
            --output-partial-info-plist "$ROOT_DIR/build/assetcatalog_info.plist" >/dev/null 2>&1 || true
    fi
fi

cat > "$APP_BUNDLE/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>seam-host</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.seam.host</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SEAM</string>
    <key>CFBundleDisplayName</key>
    <string>SEAM</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>SEAM requires Accessibility permission to detect when your cursor crosses the Mac screen edge and forward mouse and keyboard input to your Android device.</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "==> Build complete: $BIN_OUT & $APP_BUNDLE"
