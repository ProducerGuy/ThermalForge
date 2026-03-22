#!/bin/bash
#
# ThermalForge Setup
# Run once: ./setup.sh
#

set -e

cd "$(dirname "$0")"

echo "Building ThermalForge..."
swift build -c release --quiet

echo "Installing (requires admin password once)..."

# Stop existing daemon if running
sudo launchctl bootout system/com.thermalforge.daemon 2>/dev/null || true
sleep 1

# Install CLI and start daemon (copies binary to /usr/local/bin itself)
sudo xattr -cr .build/release/thermalforge
sudo .build/release/thermalforge install

# Create .app bundle in /Applications so it shows in Spotlight/Finder
APP_DIR="/Applications/ThermalForge.app/Contents"
sudo mkdir -p "$APP_DIR/MacOS"
sudo cp .build/release/ThermalForgeApp "$APP_DIR/MacOS/ThermalForgeApp"
sudo xattr -cr /Applications/ThermalForge.app

sudo tee "$APP_DIR/Info.plist" > /dev/null << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ThermalForge</string>
    <key>CFBundleDisplayName</key>
    <string>ThermalForge</string>
    <key>CFBundleIdentifier</key>
    <string>com.thermalforge.app</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleExecutable</key>
    <string>ThermalForgeApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Update Spotlight index
sudo mdimport /Applications/ThermalForge.app 2>/dev/null || true

echo ""
echo "ThermalForge installed."
echo "  - Open from Spotlight: search 'ThermalForge'"
echo "  - Open from Finder: Applications > ThermalForge"
echo "  - Or from terminal: open /Applications/ThermalForge.app"
echo ""
echo "Turn on 'Launch at Login' in the menu bar dropdown and it starts automatically."
