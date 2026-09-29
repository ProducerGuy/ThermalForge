# ThermalForge

**Free, open-source fan control for Apple Silicon Macs.** Menu bar app + CLI.

Built in 2026 with Swift. No subscriptions, no telemetry, no ads.

[![CI](https://github.com/ProducerGuy/ThermalForge/actions/workflows/ci.yml/badge.svg)](https://github.com/ProducerGuy/ThermalForge/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%E2%80%93M5-orange)](https://support.apple.com/en-us/116943)

---

## Why ThermalForge?

Tools like **Macs Fan Control** and **TG Pro** charge $15–$20 for fan control that hasn't fundamentally improved in years. Both require manual configuration, neither learns anything about your machine, and both have documented problems on Apple Silicon.

| Feature | ThermalForge | Macs Fan Control | TG Pro |
|---|---|---|---|
| Smart adaptive fan curve | **Yes** | No | No |
| Machine-specific calibration | No | No | No |
| Multi-sensor safety | **Yes — all sensors** | [One sensor per fan](https://github.com/crystalidea/macs-fan-control/issues/266) | Manual rules only |
| Proactive cooling (ramps before throttle) | **Yes** | No | No |
| Fan curve type | Per-profile shapes (ease-in, linear, S-curve, instant) | Linear between 2 points | Manual step-function |
| Real-time temp monitoring | Yes | Yes | Yes |
| Menu bar app | Yes | Yes | Yes |
| CLI access | **Yes** | No | No |
| Thermal data logging (CSV) | **Yes** | No | Yes |
| Process correlation in logs | **Yes** | No | No |
| Sleep/wake re-apply | Yes | Yes | Yes |
| Safety override (95°C) | **Yes — daemon-enforced, works with app closed** | No | Requires manual setup |
| Crash recovery (heartbeat watchdog) | **Yes — daemon-enforced, holds during overheat** | Reverts on quit only | Override removes macOS safety |
| Open source | **Yes** | No | No |
| Price | **Free** | $15 | $20 |

### Known problems with alternatives

**Macs Fan Control** monitors only one temperature sensor per fan. Users have reported [GPU overheating while monitoring CPU only](https://github.com/crystalidea/macs-fan-control/issues/266), leading to system lockups. Fan control is [broken on M3/M4 Pro and Max](https://github.com/crystalidea/macs-fan-control/issues/785) due to Apple firmware changes.

**TG Pro** offers more flexibility but requires users to manually configure step-function rules for each fan speed threshold. Its "Override System" mode removes macOS thermal safety entirely — if your rules are wrong, there's no backstop. No learning, no adaptation, no calibration.

**AlDente Pro** ($30) is a battery management tool with no fan control features. It monitors battery temperature and pauses charging — it does not control fans.

## Features

- Real-time CPU, GPU, RAM, SSD, and ambient temperatures in the menu bar
- Five fan profiles with proportional curves (not binary on/off)
- Thermal logging — CSV + JSON data export with process correlation for research
- Automatic fan re-apply after sleep/wake
- Fahrenheit / Celsius toggle
- Safety override: the background daemon forces fans to maximum if a critical sensor crosses 95°C while a manual hold is keeping them too low — enforced in the daemon, so it works even with the menu bar app closed
- Crash recovery: the daemon's heartbeat watchdog resets fans to Apple defaults if the app dies — and if a thermal safety override is active, it holds fans at max and defers the reset until the machine cools, so it never hands hot fans back to auto
- Temperature anomaly detection: logs instant spikes (>5°C in 2s) and sustained changes (>10°C in 30s) with process capture
- Privileged daemon — one-time sudo, zero password prompts after
- Native Swift — lightweight, no Electron, no bloat

## Profiles

Every profile uses a proportional curve with a per-profile curve shape — fans ramp gradually with temperature, not as binary switches. All profiles share a unified 50°C off threshold (matching Apple's observed behavior). Each profile has its own sustained trigger duration — fans only engage after temperature stays above the start threshold for a profile-specific number of seconds, filtering transient spikes that resolve on their own. Reacting to transient spikes would cause the start/stop cycling that is the #1 cause of fan bearing wear (source: [Analog Devices fan control](https://www.analog.com/en/analog-dialogue/articles/how-to-control-fan-speed.html)).

Thermal polling runs at 100ms (matching Apple's own thermalmonitord cadence) for smooth fan transitions. Each profile has its own ramp rates and curve shape tuned to its purpose. Ramp governor design sourced from [MAX31760 datasheet](https://www.analog.com/media/en/technical-documentation/data-sheets/max31760.pdf) and [Microchip AN771](https://ww1.microchip.com/downloads/en/appnotes/00771a.pdf).

| Profile | Fans off | Fans start | Ceiling | Max fan | Curve | Sustained trigger | Behavior |
|---|---|---|---|---|---|---|---|
| **Silent (Apple Default)** | N/A | N/A | N/A | Apple | N/A | N/A | Monitoring only. Apple controls fans. |
| **Balanced** | 50°C | 55°C | 70°C | 60% | Ease-in (pos²) | 8 seconds | Quiet at low temps, ramps harder as heat builds. |
| **Performance** | 50°C | 55°C | 65°C | 85% | Linear | 4 seconds | Direct proportional response, 2× ramp-up speed. |
| **Max** | 50°C | 65°C | — | 100% | Instant | 5 seconds | Attack dog: instant 100% when triggered, linear ramp-down. |
| **Smart** | 50°C | 53°C | 85°C | 100% | S-curve | 6 seconds | Proactive with rate-of-change awareness. Starts 2°C earlier. |

**How profiles work:**
- **Below 50°C:** All fans off. Machine is at idle.
- **50°C–start (hysteresis zone):** Fans maintain current state. Already running → stay at minimum. Already off → stay off.
- **Above start for N seconds:** Fans engage. Balanced and Performance ramp proportionally using their curve shape. Max jumps instantly to 100%.
- **Between start and ceiling:** Fan speed scales based on the profile's curve shape. Balanced (ease-in) is quiet at low temps — at 62.5°C (midpoint of 55–70°C), fans run at only 15% of max RPM instead of 30% linear. Performance (linear) is proportional. Max has no proportional zone — it's binary.
- **At ceiling and above:** Fan speed at the profile's maximum (60%/85%/100%).
- **Ramp down:** Each profile has its own ramp-down rate. Max uses a gentle governor to let temps stabilize before backing off.

### Custom profiles

Drop a JSON file in `~/Library/Application Support/ThermalForge/profiles/`. A file whose `id` matches a built-in replaces it; any other `id` is added as a new profile. Both the menu bar picker and `thermalforge watch --profile <id>` read the same directory. Relaunch the app to pick up changes.

This one keeps the `balanced` id, so it replaces the built-in Balanced rather than adding a sixth entry to the picker. It widens the band to 62–85°C and drops the cap to 45%, trading higher steady temperatures for less fan noise under sustained load:

```json
{
  "id": "balanced",
  "name": "Balanced",
  "curve": {
    "stopTemp": 50, "startTemp": 62, "ceilingTemp": 85,
    "maxRPMPercent": 0.45, "curveShape": "easeIn",
    "rampUpPerSec": 0.05, "rampDownPerSec": 0.025,
    "sustainedTriggerSec": 8,
    "handsOff": false, "alwaysOn": false, "instantEngage": false
  }
}
```

Give it any other `id` instead and it appears as an additional profile alongside the built-ins.

Every `curve` field is required. A file is skipped, and the reason written to the app's log in `~/Library/Logs/ThermalForge/`, when it can't be read or decoded, claims the reserved `silent` or `smart` id (the code branches on both by id), or describes a curve that can't be used. The built-in stays in place when that happens. A usable curve needs:

- `stopTemp` between 20°C and 90°C, and `startTemp` at least 5°C above it — the project's hysteresis rule, since start/stop cycling is the main cause of fan bearing wear
- `startTemp` below and `ceilingTemp` no higher than the 95°C safety threshold, so the profile is reachable before the override fires
- `ceilingTemp` above `startTemp`, or equal to it when `instantEngage` is set
- `maxRPMPercent` in 0–1, positive ramp rates, `sustainedTriggerSec` of 0–300
- `alwaysOn` off, since it would hold the fans at a fixed speed and never hand them back

The 95°C safety override and the daemon's crash watchdog apply to custom profiles exactly as they do to the built-ins — they're enforced in the daemon, which knows nothing about profiles.

## Install

### Option A: Homebrew (recommended)

```bash
brew tap ProducerGuy/tap
brew trust --formula ProducerGuy/tap/thermalforge
brew install thermalforge
sudo thermalforge install
```

Homebrew requires third-party taps to be trusted before it will run their formula, which is the `brew trust` step (per-formula, Homebrew's recommended form). `brew install` builds and installs the **CLI**. `sudo thermalforge install` then sets up the background daemon (so the app can control fans without a password every time) **and copies the menu bar app into `/Applications`**. You only run it once.

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

## Security

ThermalForge controls fans through a background daemon, and 0.2.0 locks down how you talk to it:

- **Private control socket.** The daemon listens on `/var/run/thermalforge.sock`, mode `0600`, owned by the user who ran `sudo thermalforge install`. Only that user and root can send fan commands — no other local account can drive your fans.
- **Structured, versioned protocol.** The CLI, app, and daemon speak a size-capped, versioned message format. Oversized or malformed input is rejected rather than parsed, and a version mismatch surfaces as an "Update needed" prompt instead of silent divergence.
- **Safety enforced in the daemon.** RPM requests above a fan's maximum are clamped in the daemon, not just the app. Commands are rate-limited. A thermal floor forces fans to maximum if a critical sensor crosses 95°C while a manual hold is keeping them too low — and it runs in the background service, so it works even with the menu bar app closed.
- **Robust connection handling.** Connections are handled concurrently, bounded, and timed out, so a stuck or slow client can't stall fan control.

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

### How Smart works

**The curve:** Smart maps temperature to fan speed across a 53–85°C range using an S-curve (gentle at both ends, steeper in the middle). Below 50°C, fans turn off. Between 50–53°C, fans maintain current state (hysteresis). Above 85°C, fans go to max.

**Rate-of-change awareness:** Smart doesn't just look at where temperature is — it looks at how fast it's moving. If temp is rising at 1°C/sec, Smart boosts fan speed proportionally to get ahead of the climb. If temp is stable or falling, Smart holds steady or eases off gradually.

**Ramp governors:** Fan speed changes are rate-limited for acoustic comfort. Each profile has its own ramp rates — Smart uses ~400 RPM/sec up, ~200 RPM/sec down. This prevents acoustic shock, reduces mechanical stress, and extends fan bearing lifespan by up to 50% compared to abrupt speed changes (source: [NMB fan engineering](https://nmbtc.com/white-papers/dc-brushless-cooling-fan-behavior/), [Analog Devices ADM1031 datasheet](https://www.onsemi.com/download/data-sheet/pdf/adm1031-d.pdf)).

**Hysteresis:** Fans turn on at 53°C (after 6 seconds sustained) and turn off at 50°C — a 3°C gap. Balanced and Performance use 55°C start with a 5°C gap. Max uses 65°C start with a 15°C gap. This prevents rapid on/off cycling, which is the #1 cause of fan bearing wear in fluid dynamic bearing fans (source: [Nidec FDB technology](https://www.nidec.com/en/technology/capability/fdb/), [AnandTech fan lifespan discussion](https://forums.anandtech.com/threads/fan-stop-start-effect-on-lifespan.2284098/)).

**0 to minimum RPM is binary:** Apple Silicon MacBook fans cannot spin below their minimum RPM (2317 on M5 Max, 1200 on M1 Max). When Smart decides fans should run, they jump directly to minimum — this is a hardware limitation of brushless DC motors that require a startup burst to overcome static friction. Above minimum, all speed changes are smooth and governed.

### FAQ

**What if ThermalForge closes during normal use?**
The daemon's heartbeat watchdog detects the app is gone within 15 seconds and resets fans to Apple defaults. On next launch, the app syncs to whatever the daemon is currently holding rather than forcing a reset — so a hold you set deliberately (e.g. `sudo thermalforge max`) survives. If a thermal safety override is active when the app dies, the watchdog keeps fans at maximum and defers the reset until the machine has cooled below the safety threshold — it never drops fans back to auto while the machine is hot.

### Resets and troubleshooting

**Reset fans right now:**
```bash
thermalforge auto
```
Resets the fans to Apple defaults and leaves your menu bar app running. Add `--stop-app` if you also want to quit the app so the reset sticks — otherwise a running profile re-applies its curve within seconds. With `--stop-app` the menu bar icon disappears (that's expected); relaunch from Spotlight or `/Applications` when you're done.

**Fans loud and won't stop? Reset them now:**
```bash
sudo killall ThermalForgeApp; sudo /usr/local/bin/thermalforge auto
```
This always works, even if the app isn't running. It stops ThermalForge and hands fan control straight back to macOS — your fans will settle to normal within a few seconds. It writes directly to the hardware, so it doesn't depend on the app or the background service being healthy.

**Completely remove ThermalForge:**
```bash
sudo thermalforge uninstall
```
Removes the daemon, binary, app, and all logs. Clean slate.

If installed via Homebrew, run `brew uninstall thermalforge` first.

**"Update needed" after a Homebrew upgrade:** `brew upgrade` updates the app and CLI, but the background daemon keeps running the old build until you re-sync it. While they differ, the menu bar shows an **"Update needed"** banner and the CLI prints a version-mismatch warning, both naming the two versions. Fix it once with `sudo thermalforge install`; the banner clears when they match again.

### Disclaimer

ThermalForge is provided as-is with no warranty. Use at your own risk.

## CLI

```bash
thermalforge status        # JSON output: fan speeds + temps
thermalforge max           # Max fans — no sudo when the daemon is running
thermalforge auto          # Reset to Apple defaults
thermalforge set 4000      # Set specific RPM — no sudo when the daemon is running
thermalforge discover      # Dump all SMC keys (for new hardware)
thermalforge watch         # Monitor mode with auto-boost profiles (requires sudo)
thermalforge log           # Record thermal data to CSV (1Hz, auto-delete 24h)
thermalforge log --rate 10 --duration 1h --no-expire   # 10Hz for 1 hour, keep forever
```

`max` and `set` need root to unlock the fans, so when the daemon is installed they route through it and **don't need `sudo`**; without a daemon (e.g. an uninstalled from-source build) they write the hardware directly and need `sudo`. `auto` also routes through the daemon but never needed the unlock — resetting just hands control back to macOS. `watch` always needs `sudo` (it runs its own root monitor loop). Control a single fan with `--fan`, e.g. `thermalforge set 3000 --fan 1`.

Fans settle **near** a commanded target rather than exactly on it, so `status` and the menu bar report an RPM slightly above or below what you set — that's the live tach reading, not an error.

Set fans from the terminal and the menu bar app shows a **"Fans held from Terminal"** banner and pauses its automatic control so it won't fight you — press **Default** (or pick a profile) to release the hold.

## Compatibility

Tested on MacBook Pro M5 Max (Mac17,7). Should work on M1–M5 MacBooks.
Run `thermalforge discover` on your machine and [submit a compatibility report](../../issues/new?template=compatibility-report.md).

| Machine | Chip | Status |
|---|---|---|
| MacBook Pro 16" (2025) | M5 Max | Tested |
| Mac Studio (2022) | M2 Ultra | Tested |
| MacBook Pro 16" (2021) | M1 Max | Tested |
| MacBook Pro 16" M5 Pro (Mac17,8) | M5 Pro | Reported |
| MacBook Pro 14" M5 Pro (Mac17,9) | M5 Pro | Reported |
| MacBook Pro M4 Max (Mac16,5) | M4 Max | Reported |
| MacBook Pro M3 Max (2023, 128GB) | M3 Max | Reported |
| MacBook Pro 14" M2 Pro (2023) | M2 Pro | Reported |
| MacBook Pro 14" M2 Max (2023) | M2 Max | Reported |
| MacBook Pro M1 (2020) | M1 | Reported |

SMC key names vary across chip generations — ThermalForge auto-detects at startup. The `discover` command dumps all keys so we can verify what your hardware uses. The more machines tested, the more robust ThermalForge becomes.

## Uninstall

### Homebrew

```bash
brew uninstall thermalforge
sudo thermalforge uninstall
```

`thermalforge uninstall` removes the daemon, binary, app, calibration data, and all logs.

### From source

```bash
sudo thermalforge uninstall
```

This removes the daemon, binary, app bundle, calibration data, and all logs.

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

### Storage

ThermalForge has three types of stored data, all automatically managed:

**App log** (daily files in `~/Library/Logs/ThermalForge/`) — one file per day (`thermalforge-2026-04-05.log`). Records all app events: profile changes, fan commands, temperature spikes, safety overrides, sustained trigger events. Auto-deletes files older than 7 days on app launch. Each daily file is small and easy to open or share.

**Research session logs** (`thermalforge log` exports in `~/Library/Application Support/ThermalForge/logs/`) — CSV/JSON research data. Auto-delete after 24 hours by default. Use `--no-expire` to keep permanently.

Nothing accumulates indefinitely. All cleanup runs automatically on app launch.

## Future Specs

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
