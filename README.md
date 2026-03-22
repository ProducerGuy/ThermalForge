# ThermalForge

**Free, open-source fan control for Apple Silicon Macs.** Menu bar app + CLI.

Built in 2026 with Swift. No subscriptions, no telemetry, no ads.

[![CI](https://github.com/ProducerGuy/ThermalForge/actions/workflows/ci.yml/badge.svg)](https://github.com/ProducerGuy/ThermalForge/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%E2%80%93M5-orange)](https://support.apple.com/en-us/116943)

---

## Why ThermalForge?

Tools like **Macs Fan Control**, **TG Pro**, and **AlDente Pro** charge $15–$30+ for fan control on Mac. ThermalForge does the same thing for free:

| Feature | ThermalForge | Macs Fan Control Pro | TG Pro | AlDente Pro |
|---|---|---|---|---|
| Custom fan profiles | Yes | $15 | $20 | $30 |
| Real-time temp monitoring | Yes | Yes | Yes | Yes |
| Menu bar app | Yes | Yes | Yes | Yes |
| CLI access | Yes | No | No | No |
| Sleep/wake re-apply | Yes | Yes | Yes | No |
| Safety override (95°C) | Yes | No | Yes | No |
| Open source | **Yes** | No | No | No |
| Price | **Free** | $15 | $20 | $30 |

## Features

- Real-time CPU, GPU, RAM, SSD, and ambient temperatures in the menu bar
- Four fan profiles: Silent, Balanced (60%), Performance (85%), Max (100%)
- Automatic fan re-apply after sleep/wake
- Fahrenheit / Celsius toggle
- Safety override: forces max fans if any sensor hits 95°C
- Privileged daemon — one-time sudo, zero password prompts after
- Native Swift — lightweight, no Electron, no bloat

## Install

### Option A: Homebrew (recommended)

```bash
brew install ProducerGuy/tap/thermalforge
sudo thermalforge install
```

The first command installs the CLI and the menu bar app to `/Applications`. The second sets up a background daemon so the app can control fans without needing sudo every time. You only run it once.

### Option B: From source

```bash
git clone https://github.com/ProducerGuy/ThermalForge.git
cd ThermalForge
./setup.sh
```

Builds everything, installs the CLI, creates the menu bar app in `/Applications`, and sets up the daemon. One password prompt, fully automatic.

### After install

Open ThermalForge from Spotlight, Finder (Applications > ThermalForge), or terminal:

```bash
open /Applications/ThermalForge.app
```

Turn on **Launch at Login** in the menu bar dropdown and it starts automatically on every boot.

## CLI

```bash
thermalforge status        # JSON output: fan speeds + temps
thermalforge max           # Max fans (requires daemon or sudo)
thermalforge auto          # Reset to Apple defaults
thermalforge set 4000      # Set specific RPM
thermalforge discover      # Dump all SMC keys (for new hardware)
thermalforge watch          # Monitor mode with auto-boost profiles
```

## Compatibility

Tested on MacBook Pro M5 Max (Mac17,7). Should work on M1–M5 MacBooks.
Run `thermalforge discover` on your machine and [submit a compatibility report](../../issues/new?template=compatibility-report.md).

| Machine | Chip | Status |
|---|---|---|
| MacBook Pro 16" (2025) | M5 Max | Tested |
| Mac Studio (2022) | M2 Ultra | Tested |
| MacBook Pro 16" (2021) | M1 Max | Tested |

SMC key names vary across chip generations — ThermalForge auto-detects at startup. The `discover` command dumps all keys so we can verify what your hardware uses. The more machines tested, the more robust ThermalForge becomes.

## Uninstall

### Homebrew

```bash
sudo thermalforge uninstall
brew uninstall thermalforge
sudo rm -rf /Applications/ThermalForge.app
```

### From source

```bash
./uninstall.sh
```

Or manually:

```bash
sudo thermalforge uninstall
sudo rm -f /usr/local/bin/thermalforge
sudo rm -rf /Applications/ThermalForge.app
```

## Contributing

ThermalForge is a solo project but compatibility reports are hugely valuable. If you have an Apple Silicon Mac:

1. Install ThermalForge
2. Run `thermalforge discover --output discover.txt`
3. [Open a compatibility report](../../issues/new?template=compatibility-report.md) and attach the file

That's it. Every new machine tested makes ThermalForge better for everyone.

## Coming Soon: Thermal Logging

Research-grade thermal data export — CSV + JSON, process correlation, configurable sample rates. Built for reproducible analysis, cross-machine comparison, and hardware research. See [ROADMAP.md](ROADMAP.md) for details.

## License

[MIT](LICENSE) — free to use, modify, and distribute.
