# ThermalForge

Low-level fan control for Apple Silicon macOS (14+), implemented in Swift.

- Menu bar app (`ThermalForgeApp`)
- CLI (`thermalforge`)
- Privileged launchd daemon (`com.thermalforge.daemon`)

Original creator: **[ProducerGuy](https://github.com/ProducerGuy/ThermalForge)**.
This repository is an actively maintained fork.

## Release

Current fork release: **`v0.2.0`**

- Release page: <https://github.com/d37atm/ThermalForge/releases/tag/v0.2.0>
- Artifacts:
  - `ThermalForge-v0.2.0-macos-arm64-app.zip`
  - `ThermalForge-v0.2.0-macos-arm64-cli.tar.gz`
  - `checksums.txt`

`v0.2.0` adds:
- typed daemon protocol (`DaemonRequest` / `DaemonResponse`) with legacy command fallback
- rule engine (IF/THEN with priority + latch/until)
- extracted control state machine + service
- unified built-in profiles (Smart included)
- structured event logging + expanded tests
- hardened app bundle/release pipeline

## Architecture

`ThermalForgeCore` is split into explicit layers:

1. **Hardware**
- SMC adapter (`FanControl`)
- test seams: `FanController`, `SensorProvider`

2. **Control**
- `ThermalMonitor` runtime loop
- `ControlService`, `ControlStateMachine`
- `RuleEngine`, `RulePersistence`

3. **Transport**
- daemon socket: `/var/run/thermalforge.sock`
- protocol: `DaemonRequest`, `DaemonResponse`, `DaemonCodec`

4. **Observability**
- rotating text logs (`~/Library/Logs/ThermalForge`)
- structured events (`thermalforge-events-YYYY-MM-DD.jsonl`)
- research logger (`thermalforge log`)

## Safety Model

Execution precedence:
1. hard safety override (`>=95°C` -> max fan)
2. rule engine decisions
3. profile curve logic

Daemon boundary:
- launchd system daemon (`root`)
- local Unix socket with restrictive permissions
- peer UID authorization (root or active console user)
- heartbeat watchdog resets fans if client disappears

## Profiles

Built-in:
- `silent`
- `balanced`
- `performance`
- `max`
- `smart`

Control loop:
- thermal cadence: 100ms
- monitor cadence: 2s
- UI cadence: 500ms

## Rules (IF/THEN)

Rules are persisted at:
- `~/Library/Application Support/ThermalForge/rules.json`

CLI:
```bash
thermalforge rules list
thermalforge rules add --trigger 55 --until 65 --max
thermalforge rules enable <rule-id>
thermalforge rules disable <rule-id>
thermalforge rules remove <rule-id>
thermalforge rules test --cpu 70 --gpu 62 --profile balanced
```

## Install

### Homebrew
```bash
brew install ProducerGuy/tap/thermalforge
sudo thermalforge install
```

### Source
```bash
git clone https://github.com/d37atm/ThermalForge.git
cd ThermalForge
./setup.sh
```

Open app:
```bash
open /Applications/ThermalForge.app
```

## Build / Test

```bash
swift build
swift test
./Scripts/ci-smoke.sh
```

Release build scripts:
- `Scripts/version.sh`
- `Scripts/build-app-bundle.sh`
- `Scripts/ci-smoke.sh`

CI workflows:
- `.github/workflows/ci.yml` (build + test + package smoke)
- `.github/workflows/release.yml` (tag-based artifact release)

## CLI Quick Reference

```bash
thermalforge status
thermalforge max
thermalforge auto
thermalforge set 4000
thermalforge watch --profile smart
thermalforge discover
thermalforge log --rate 10 --duration 1h --no-expire
```

## Troubleshooting

If macOS blocks the app after download:
```bash
xattr -dr com.apple.quarantine /Applications/ThermalForge.app
codesign --force --deep --sign - /Applications/ThermalForge.app
open /Applications/ThermalForge.app
```

Reset fans immediately:
```bash
thermalforge auto
```

## License

MIT
