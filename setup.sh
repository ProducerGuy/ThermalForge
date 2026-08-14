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

# Kill old app and reset fans
pkill -x ThermalForgeApp 2>/dev/null || true
sleep 1
/usr/local/bin/thermalforge auto 2>/dev/null || true

# Generate app icon if needed
if [ ! -f ThermalForge.icns ]; then
    echo "Generating app icon..."
    swift Scripts/generate-icon.swift
    iconutil -c icns ThermalForge.iconset -o ThermalForge.icns
fi

# Install CLI and daemon (handles stopping old daemon if present)
sudo xattr -cr .build/release/thermalforge
sudo .build/release/thermalforge install

# Create the .app bundle in /Applications via the single shared assembler.
# Version and macOS floor come from ThermalForgeVersion — no hardcoding, and
# byte-identical to the bundle the Homebrew path assembles.
sudo .build/release/thermalforge build-app \
    --binary .build/release/ThermalForgeApp \
    --icon ThermalForge.icns \
    --dest /Applications/ThermalForge.app
sudo xattr -cr /Applications/ThermalForge.app

# Update Spotlight index
sudo mdimport /Applications/ThermalForge.app 2>/dev/null || true

echo ""
echo "ThermalForge installed."
echo "  - Open from Spotlight: search 'ThermalForge'"
echo "  - Open from Finder: Applications > ThermalForge"
echo "  - Or from terminal: open /Applications/ThermalForge.app"
echo ""
echo "Turn on 'Launch at Login' in the menu bar dropdown and it starts automatically."
