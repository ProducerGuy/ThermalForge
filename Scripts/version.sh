#!/bin/bash
set -euo pipefail

# Single source of truth is ThermalForgeVersion.current in Swift source.
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/Sources/ThermalForgeCore/ThermalForgeVersion.swift"

THERMALFORGE_VERSION="$(
  grep -Eo 'current = "[0-9]+\.[0-9]+\.[0-9]+"' "$VERSION_FILE" \
    | head -n1 \
    | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/'
)"

if [ -z "${THERMALFORGE_VERSION:-}" ]; then
  echo "Failed to extract THERMALFORGE_VERSION from $VERSION_FILE" >&2
  exit 1
fi

export THERMALFORGE_VERSION
