#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/Scripts/version.sh"

APP_PATH="${1:-/Applications/ThermalForge.app}"
APP_CONTENTS="$APP_PATH/Contents"
APP_BIN="$ROOT_DIR/.build/release/ThermalForgeApp"
ICON_PATH="$ROOT_DIR/ThermalForge.icns"

mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources"
cp "$APP_BIN" "$APP_CONTENTS/MacOS/ThermalForgeApp"
chmod +x "$APP_CONTENTS/MacOS/ThermalForgeApp"

if [ -f "$ICON_PATH" ]; then
  cp "$ICON_PATH" "$APP_CONTENTS/Resources/AppIcon.icns"
fi

cat > "$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ThermalForge</string>
  <key>CFBundleDisplayName</key><string>ThermalForge</string>
  <key>CFBundleIdentifier</key><string>com.thermalforge.app</string>
  <key>CFBundleVersion</key><string>${THERMALFORGE_VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${THERMALFORGE_VERSION}</string>
  <key>CFBundleExecutable</key><string>ThermalForgeApp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || true
fi

xattr -cr "$APP_PATH" || true
plutil -lint "$APP_CONTENTS/Info.plist" >/dev/null
