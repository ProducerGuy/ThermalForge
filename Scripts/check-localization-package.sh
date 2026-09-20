#!/bin/bash
# Validate packaging without opening the app or touching installed files.
set -euo pipefail
cd "$(dirname "$0")/.."
bin_dir="${1:-$(swift build --show-bin-path)}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/thermalforge-package.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
bundle=ThermalForge_ThermalForgeLocalization.bundle
# The assembler only copies the icon; a fixture avoids an unrelated icon build.
: > "$check_dir/icon.icns"
"$bin_dir/thermalforge" build-app --binary "$bin_dir/ThermalForgeApp" --icon "$check_dir/icon.icns" --dest "$check_dir/Check.app"
resource_dir="$check_dir/Check.app/Contents/Resources/$bundle"
if [ -d "$resource_dir/Contents/Resources" ]; then resource_dir="$resource_dir/Contents/Resources"; fi
for language in en zh-Hans zh-Hant; do
 cmp "Sources/ThermalForgeLocalization/Resources/$language.json" "$resource_dir/$language.json"
done
mkdir "$check_dir/unbundled"
cp "$bin_dir/ThermalForgeApp" "$check_dir/unbundled/ThermalForgeApp"
echo preserve > "$check_dir/Check.app/sentinel"
if "$bin_dir/thermalforge" build-app --binary "$check_dir/unbundled/ThermalForgeApp" --icon "$check_dir/icon.icns" --dest "$check_dir/Check.app" > "$check_dir/rejection.log" 2>&1; then
 echo "Unexpected success with missing localization resources" >&2
 exit 1
fi
test "$(cat "$check_dir/Check.app/sentinel")" = preserve
printf 'Localization packaging and missing-resource protection passed.\n'
