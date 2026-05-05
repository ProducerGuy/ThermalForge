# ThermalForge

Open-source fan control for Apple Silicon Macs.

- Native Swift CLI + menu bar app
- Privileged launchd daemon (no repeated sudo prompts)
- Safety-first thermal control with 95°C override
- Profile curves + IF/THEN rule engine
- Research logging (CSV + JSON metadata)

## Features

- Profiles: Silent, Balanced, Performance, Max, Smart
- Rule engine (priority-based):
  - Example: `IF maxTemp >= 55 THEN set max fan until <= 65`
- Sleep/wake command re-apply via daemon
- Heartbeat watchdog resets fans if app dies
- Structured event logging (`jsonl`) + rotating plain logs

## Install

### Homebrew

```bash
brew install ProducerGuy/tap/thermalforge
sudo thermalforge install
```

### From Source

```bash
git clone https://github.com/ProducerGuy/ThermalForge.git
cd ThermalForge
./setup.sh
```

`setup.sh` now uses a hardened app-bundle builder:
- `Scripts/build-app-bundle.sh`
- validated `Info.plist`
- executable permission checks
- ad-hoc signing + quarantine cleanup

## Run

```bash
open /Applications/ThermalForge.app
```

## CLI

```bash
thermalforge status
thermalforge max
thermalforge auto
thermalforge set 4000
thermalforge watch --profile smart
thermalforge discover
thermalforge log --rate 10 --duration 1h --no-expire
```

### Rules CLI

```bash
thermalforge rules list
thermalforge rules add --trigger 55 --until 65 --max
thermalforge rules enable <rule-id>
thermalforge rules disable <rule-id>
thermalforge rules remove <rule-id>
thermalforge rules test --cpu 70 --gpu 62 --profile balanced
```

## Safety

- Hard override: any sensor >= 95°C -> max fan
- Hysteresis + sustained triggers reduce oscillation
- Daemon authorization: root or active console user only
- Socket: `/var/run/thermalforge.sock` with restrictive perms

## Development

```bash
swift build
swift test
./Scripts/ci-smoke.sh
```

CI workflows:
- `.github/workflows/ci.yml`: build + tests + package smoke
- `.github/workflows/release.yml`: release artifact packaging

## Uninstall

```bash
sudo thermalforge uninstall
```

Removes daemon, CLI, app bundle, and ThermalForge user data/logs.

## License

MIT
