# ThermalForge

Fan control for Apple Silicon MacBooks. Menu bar app + CLI.

## Install

```bash
git clone https://github.com/ProducerGuy/ThermalForge.git
cd ThermalForge
./setup.sh
```

One password prompt. After that:
- **Spotlight:** search "ThermalForge"
- **Finder:** Applications > ThermalForge
- **Terminal:** `open /Applications/ThermalForge.app`

Turn on **Launch at Login** in the dropdown and it starts automatically on every boot.

## What It Does

- Real-time CPU, GPU, RAM, SSD, and ambient temperatures in the menu bar
- Four fan profiles: Silent, Balanced (60%), Performance (85%), Max (100%)
- Automatic fan re-apply after sleep/wake
- °F / °C toggle
- Safety override: forces max fans if any sensor hits 95°C

## CLI

```bash
thermalforge status        # JSON output: fan speeds + temps
thermalforge max           # Max fans (requires daemon or sudo)
thermalforge auto          # Reset to Apple defaults
thermalforge set 4000      # Set specific RPM
thermalforge discover      # Dump all SMC keys (for new hardware)
thermalforge watch          # Monitor mode with auto-boost profiles
```

## Homebrew

```bash
brew install ProducerGuy/tap/thermalforge
```

## Uninstall

```bash
./uninstall.sh
```

Or manually:
```bash
sudo thermalforge uninstall
sudo rm -f /usr/local/bin/thermalforge /usr/local/bin/thermalforge-app
sudo rm -rf /Applications/ThermalForge.app
```

## Compatibility

Tested on MacBook Pro M5 Max (Mac17,7). Should work on M1–M5 MacBooks.
Run `thermalforge discover` on your machine and [submit a compatibility report](../../issues/new?template=compatibility-report.md).

## License

MIT
