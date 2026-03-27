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

## Smart Profile

### Why proactive cooling matters

Apple's default fan behavior is reactive: fans stay off until the chip is already hot, then ramp up to recover. This creates a repeating cycle during sustained workloads like renders, compiles, and ML inference:

1. CPU/GPU runs at full clocks, heat builds unchecked
2. Chip hits ~90°C, starts throttling clock speeds — **10-20% performance loss**
3. Fans finally ramp up
4. Temps drop, clocks recover, fans slow down
5. Heat builds again — repeat

This sawtooth pattern costs you sustained performance, wears hardware faster (thermal cycling stress on solder joints follows the Coffin-Manson fatigue model — damage scales with temperature swing amplitude, not absolute temperature), and forces fans to work harder because they're always recovering instead of preventing.

The Smart profile eliminates this. It monitors temperature velocity — not just where the temp is, but how fast it's rising — and ramps fans early enough to hold the chip below 85°C. The result: sustained peak clocks throughout your entire workload, less thermal cycling wear, and fans that run quieter overall because they never need to recover from a heat spike.

Apple doesn't do this because silence sells in store demos and most users never run sustained workloads. ThermalForge gives power users the choice Apple doesn't.

### Calibration

For best results, calibrate Smart to your specific machine:

```bash
sudo thermalforge calibrate                    # Standard (~28 min)
sudo thermalforge calibrate --mode quick       # Quick (~10 min)
sudo thermalforge calibrate --mode thorough    # Until stable (~35-50 min)
```

Calibration stresses both CPU and GPU simultaneously using Metal compute shaders — the same combined-load approach used by [Notebookcheck](https://www.notebookcheck.net) (Prime95 + FurMark) and [Gamers Nexus](https://gamersnexus.net/guides/3561-cpu-cooler-testing-methodology-most-tests-are-flawed) for thermal testing. On Apple Silicon, CPU and GPU share the same die and unified memory, so combined stress is the only way to capture real-world worst-case thermal behavior.

At each of 4 fan speed levels (25%, 50%, 75%, 100%), calibration measures how fast the machine heats, where temperature stabilizes, and how fast it cools. Results are saved permanently.

### Calibration modes

| Mode | Time | What it does |
|---|---|---|
| **Quick** | ~10 min | 2 min heat + 30s cool per level. Reaches ~75% of steady state. Good baseline. |
| **Standard** | ~28 min | 5 min heat + 2 min cool per level. Reaches ~95% of steady state. Recommended. |
| **Thorough** | ~35-50 min | Runs until temperature stabilizes (<0.5°C change over 60s). Guaranteed steady state. Best data. |

Timing is based on measured thermal time constants of 90-120 seconds for Apple Silicon laptop heatsink assemblies (Notebookcheck M1-M4 MacBook Pro stress tests, [Max Tech](https://www.youtube.com/@MaxTech) sustained performance testing). Three time constants (5 min) reaches 95% of steady state. Five time constants (10 min) reaches 99.3%. Mac Studio's larger thermal mass (~2-3x) is covered by Standard mode's 5-minute heating phase.

**Smart works without calibration** — it uses a conservative default curve. Calibration makes it precise for your hardware.

### FAQ

**Do I need to re-calibrate every time I use Smart?**
No. Calibration runs once and saves the results. Switch between profiles freely — Smart always has your data.

**Can I re-calibrate?**
Yes. Run `sudo thermalforge calibrate` again anytime. This overwrites the previous data. You might want to re-calibrate after a macOS update or if your cooling setup changes.

**What if I stop calibration early?**
Press Ctrl-C. Fans reset to Apple defaults immediately. No calibration data is saved. Smart continues to work with the default curve.

**What if ThermalForge closes during normal use?**
The background daemon keeps running with the last fan setting. On next launch, Smart picks up your calibration data and resumes.

**What does calibration save?**
Two files in `~/Library/Application Support/ThermalForge/`:
- `calibration.json` — machine-specific thermal data that Smart reads
- `calibration_<timestamp>.csv` — every sensor reading taken during calibration (for research use)

### Disclaimer

Calibration pushes your CPU to full load and cycles fan speeds. This is within normal operating parameters for your Mac, but ThermalForge is provided as-is with no warranty. Use at your own risk.

## CLI

```bash
thermalforge status        # JSON output: fan speeds + temps
thermalforge max           # Max fans (requires daemon or sudo)
thermalforge auto          # Reset to Apple defaults
thermalforge set 4000      # Set specific RPM
thermalforge discover      # Dump all SMC keys (for new hardware)
thermalforge watch          # Monitor mode with auto-boost profiles
thermalforge calibrate     # Calibrate Smart profile for this machine (sudo)
thermalforge log           # Record thermal data to CSV (1Hz, auto-delete 24h)
thermalforge log --rate 10 --duration 1h --no-expire   # 10Hz for 1 hour, keep forever
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

## Thermal Logging

No existing macOS tool exports structured thermal data with process correlation in a format designed for research. ThermalForge does.

### Who this is for

- **Data scientists** studying thermal behavior across Apple Silicon generations
- **Hardware engineers** validating cooling solutions or thermal pad mods
- **Developers** profiling how their apps affect system thermals
- **Researchers** who need reproducible, citable thermal data for papers

### What it captures

```bash
thermalforge log                                          # 1Hz, auto-delete after 24h
thermalforge log --rate 10 --duration 1h --no-expire      # 10Hz, 1 hour, keep forever
```

Each session produces a self-contained folder:

| File | Contents |
|---|---|
| **thermal.csv** | Timestamped readings from every detected temperature sensor, fan RPM (actual + target), fan mode, at every sample interval |
| **processes.csv** | Top 5 processes by CPU utilization at every sample — the missing link between thermal data and what caused it |
| **metadata.json** | Machine model, chip, OS version, ThermalForge version, fan count, RPM range, sample rate, complete sensor dictionary, session start/end, total sample count |

### Why this format

- **CSV + JSON sidecar** — loads directly in pandas, R, Excel, or any data tool without a custom parser
- **Raw SMC key names** — no friendly labels that could be wrong across chip generations. Cross-reference against Apple hardware documentation directly
- **Self-describing sessions** — every log folder contains everything needed to interpret the data. Hand it to someone with no context and they can work with it
- **Auto-delete by default (24h)** — prevents disk bloat for casual users. `--no-expire` for researchers who need to keep data

## Coming Soon

### Enhanced Logging

- **Thermal throttle state** — capture Apple's `ProcessInfo.thermalState` (nominal/fair/serious/critical) at every sample. Know exactly when and how hard the chip throttled.
- **Power draw** — SMC power keys (PSTR, PCPT) to capture wattage alongside temperature. Watts correlate directly with heat generation.
- **GPU utilization** — current logging captures CPU processes but GPU compute workloads (Metal, ML inference) are invisible. GPU utilization fills that gap.
- **Memory pressure** — system memory pressure percentage at every sample
- **Delta-T over ambient** — report temperatures as both absolute and delta above ambient. This is the standard comparison metric used by hardware reviewers (Gamers Nexus, Notebookcheck) because absolute temps vary with room temperature.
- **User markers** — annotate the log mid-session ("started render", "switched profile") so data points have context when analyzed later
- **Statistical summary** — min, max, mean, standard deviation, P95/P99 for all sensors across the session. Time spent in each thermal state. Peak fan RPM.

### Experiment Mode

A controlled testing framework for anyone who wants to understand their Mac's thermal behavior — modders validating thermal pad swaps, developers profiling their apps, engineers comparing cooling strategies.

```bash
thermalforge experiment --workload cpu --fan smart --duration 10m --label "smart-baseline"
thermalforge experiment --workload cpu --fan 75%  --duration 10m --label "fixed-75"
thermalforge compare smart-baseline fixed-75
```

**Controlled variables:**
- Fan speed: any profile, fixed percentage, or Smart
- Workload type: CPU stress, GPU stress (Metal compute), CPU+GPU combined, idle baseline, or any custom command
- Duration with automatic steady-state detection (temp change <0.5°C over 2 minutes)
- Ambient temperature input for Delta-T calculations

**Metrics generated per experiment:**
- Time-to-throttle — how long before the chip starts losing performance
- Time-to-steady-state — how long before temperature stabilizes
- Sustained performance score — average clock throughput over the test duration
- Statistical summary — mean, std dev, min, max, P95/P99 temps

**Comparison reports:**
- Side-by-side A/B results across experiments
- Automatic detection of statistically significant differences
- Export as CSV or formatted summary

**Built-in workloads:**
- CPU stress: saturates all cores with compute-bound work
- GPU stress: Metal compute shaders that load the GPU pipeline
- Combined: CPU + GPU simultaneously (the real-world worst case for Apple Silicon where CPU, GPU, and Neural Engine share the same die and unified memory)
- Idle baseline: 5-minute idle measurement before and after tests to establish reference

### Community Thermal Database

Opt-in anonymous upload of experiment results. Compare your machine against others with the same chip. See how your M5 Max thermal performance ranks against the distribution. Modeled after [OpenBenchmarking.org](https://openbenchmarking.org) — standardized methodology, community validation, machine fingerprinting by chip model (not serial number).

See [ROADMAP.md](ROADMAP.md) for full specs and build plans.

## License

[MIT](LICENSE) — free to use, modify, and distribute.
