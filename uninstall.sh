#!/bin/bash
#
# ThermalForge Uninstall
# Removes everything: daemon, app, CLI.
#

set -e

echo "Uninstalling ThermalForge..."

sudo /usr/local/bin/thermalforge uninstall 2>/dev/null || true
sudo rm -f /usr/local/bin/thermalforge
sudo rm -f /usr/local/bin/thermalforge-app
sudo rm -rf /Applications/ThermalForge.app
rm -rf ~/Library/Logs/ThermalForge
rm -rf ~/Library/Application\ Support/ThermalForge

echo "ThermalForge removed."
