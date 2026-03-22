#!/bin/bash
#
# ThermalForge Setup
# Run once: ./setup.sh
#

set -e

echo "Building ThermalForge..."
cd "$(dirname "$0")"
swift build -c release --quiet

echo "Installing daemon (requires admin password once)..."
sudo .build/release/thermalforge install

echo ""
echo "Done! To launch the menu bar app:"
echo "  thermalforge-app"
echo ""
echo "Or just double-click ThermalForge in your Applications folder."

# Copy app launcher to /usr/local/bin
sudo cp .build/release/ThermalForgeApp /usr/local/bin/thermalforge-app

echo "ThermalForge is ready. Run: thermalforge-app"
