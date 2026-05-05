#!/bin/bash
#
# ThermalForge Setup
# Run once: ./setup.sh
#

set -e

cd "$(dirname "$0")"
source ./Scripts/version.sh

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

# Create signed app bundle in /Applications so it shows in Spotlight/Finder
sudo ./Scripts/build-app-bundle.sh /Applications/ThermalForge.app

# Update Spotlight index
sudo mdimport /Applications/ThermalForge.app 2>/dev/null || true

echo ""
echo "ThermalForge installed."
echo "  - Open from Spotlight: search 'ThermalForge'"
echo "  - Open from Finder: Applications > ThermalForge"
echo "  - Or from terminal: open /Applications/ThermalForge.app"
echo ""
echo "Turn on 'Launch at Login' in the menu bar dropdown and it starts automatically."
