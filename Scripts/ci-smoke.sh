#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT_DIR"
swift build -c release

SMOKE_APP="$ROOT_DIR/.build/ThermalForge-smoke.app"
rm -rf "$SMOKE_APP"
"$ROOT_DIR/Scripts/build-app-bundle.sh" "$SMOKE_APP"
plutil -lint "$SMOKE_APP/Contents/Info.plist" >/dev/null

echo "CI smoke checks passed."
