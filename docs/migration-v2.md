# Migration to v2

## What Changed

- Smart profile is part of the built-in profile list.
- Daemon protocol now supports typed JSON request/response.
- Rule engine is first-class and persisted.
- Build/install pipeline uses dedicated app bundle script.
- Version value is sourced from `ThermalForgeVersion.current`.

## User Impact

- Existing profile behavior remains available.
- Existing shell command usage (`max`, `auto`, `set`, `status`) still works.
- New rule commands are available under `thermalforge rules ...`.

## Operator Checklist

1. Rebuild and reinstall:
   - `swift build -c release`
   - `sudo .build/release/thermalforge install`
2. Rebuild app bundle:
   - `sudo ./Scripts/build-app-bundle.sh /Applications/ThermalForge.app`
3. Restart daemon:
   - `sudo launchctl kickstart -k system/com.thermalforge.daemon`
4. Validate:
   - `thermalforge status`
   - `thermalforge rules list`
