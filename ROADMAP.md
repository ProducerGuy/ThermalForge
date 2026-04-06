# ThermalForge Roadmap

## Built Features

### Smart Profile (Built)

Proactive thermal curve that monitors temperature velocity and ramps fans before throttling occurs. Targets 85°C ceiling. Works with or without calibration — default conservative S-curve without data, machine-specific curve with calibration.

- Graduated continuous curve from 60°C (floor) to 85°C (ceiling)
- Rate-of-change awareness: ramps harder when temp is rising, eases off slowly when falling
- With calibration: uses temp→fan lookup table from `fanPercentForTemp()` with interpolation
- Without calibration: conservative S-curve fallback
- Ramp governors matching Apple hardware: ~400 RPM/sec up, ~200 RPM/sec down
- 5°C hysteresis (stop at 55°C, start at 60°C)


### Thermal Logging (Built)

Research-grade data export: `thermalforge log`

- CSV with all temperature sensors, fan RPM (actual + target), fan mode per sample
- Process CSV: top 5 processes by CPU at every sample
- JSON metadata: machine, OS, sensor dictionary, session info
- Configurable rate (1-10 Hz), duration, output directory
- Auto-delete after 24h by default, `--no-expire` for researchers

### Safety Systems (Built)

- 95°C safety override: forces max fans regardless of profile
- Sustained trigger: fans only engage after 8 seconds above threshold (4 consecutive readings) — filters transient spikes
- Heartbeat watchdog: daemon resets fans if app dies (15s timeout)
- Clean state on app launch: fans reset to auto before any profile activates
- Clean shutdown: fans reset on normal app quit
- SMC lock: serializes all fan control operations across daemon threads
- Duplicate instance prevention
- Calibration data validation: rejects physically impossible data
- Temperature anomaly detection: instant spikes (>5°C in 2s) and sustained changes (>10°C in 30s) with 30-second rolling process buffer
- Error logging to ~/Library/Logs/ThermalForge/thermalforge.log (1GB cap)

### In-App Calibration UI (Built)

- Mode picker (Quick/Standard/Optimized) in menu bar dropdown
- Smart button prompts calibration if no data exists, with Skip option
- Progress bar, current phase, live temperature during calibration
- Stop button: kills stress, resets fans, resets profile to Silent
- Calibration complete auto-activates Smart

---

## Profile + Smart + Calibration Redesign (Complete)

The entire profile system, Smart curve, and calibration need to be redesigned as one cohesive system. Current profiles are binary switches that immediately set fans to a fixed percentage. They should be proportional curves that respect Apple's fan hardware behavior.

### Research basis

Apple's fan hardware behavior (sources: macos-smc-fan reverse engineering, Tunabelly blog, NMB/Nidec fan motor engineering docs, Analog Devices fan controller datasheets):

- **0 to minimum RPM is binary** — fans jump from off to minimum (2317 RPM on M5 Max, 1200 on M1 Max, 1000 on Mac Studio). No slow start possible — brushless DC motors require a startup burst to overcome static friction. Hardware limitation, not software.
- **Above minimum, smooth ramping** — Apple ramps at ~350-550 RPM/sec up, ~150-300 RPM/sec down. Evaluated every 100ms with small increments.
- **Start/stop cycles are the #1 fan bearing wear factor** — fluid dynamic bearings suffer contact wear during startup (boundary lubrication before hydrodynamic film builds). Minimize on/off cycling.
- **Once spinning, keep spinning** — Apple holds fans at minimum RPM with hysteresis rather than cycling between 0 and spinning. At least 5°C hysteresis between start and stop thresholds.
- **Smoother transitions extend lifespan up to 50%** — per fan engineering literature. Abrupt speed jumps while running cause acoustic and mechanical transients.

### Profile curve design

Each profile has three zones:

**Zone 1: Off** — below the stop threshold, fans stay at 0 RPM (Apple auto).
**Zone 2: Minimum hold** — between stop threshold and start threshold (hysteresis band), fans stay at minimum RPM if already running, stay off if already off.
**Zone 3: Proportional curve** — above the start threshold, fan speed scales proportionally from minimum RPM to the profile's max RPM cap, increasing with temperature.

Ramp governors (matching Apple's behavior):
- Ramp up: max ~400 RPM/sec (~5% of max per 2-second tick)
- Ramp down: max ~200 RPM/sec (~2.5% of max per 2-second tick, already implemented)

### Profile specifications

| Profile | Fans off below | Start ramp at | Max fan speed | Target ceiling | Stop threshold |
|---|---|---|---|---|---|
| **Silent** | 73°C | 78°C | Apple default (reset to auto) | 78°C | 73°C |
| **Balanced** | 50°C | 60°C | 60% of max RPM | 70°C | 50°C |
| **Performance** | 45°C | 50°C | 85% of max RPM | 65°C | 45°C |
| **Max** | Never | Always on | 100% | N/A | N/A |
| **Smart** | 60°C | 60°C | 100% (adapts) | 85°C | 60°C |

**Balanced example curve (60-70°C, 0-60% of max RPM):**
- 60°C: fans jump to minimum RPM (2317)
- 63°C: fans at ~30% of max RPM (~2348 RPM, just above min)
- 65°C: fans at ~40% of max RPM (~3130 RPM)
- 67°C: fans at ~50% of max RPM (~3913 RPM)
- 70°C: fans at 60% of max RPM (~4696 RPM) — cap reached
- Below 50°C and stable: fans off

The curve between start and ceiling is proportional, not stepped. Fan speed = minRPM + (maxRPMCap - minRPM) × ((temp - startTemp) / (ceilingTemp - startTemp)).

**Silent** is special: it doesn't control fans directly. It stays in Apple auto mode and only intervenes if temp hits 78°C, at which point it resets to auto (letting Apple's own thermal management handle it). Below 73°C it returns to hands-off. This is for users who want ThermalForge monitoring without fan control.

### Smart curve redesign

Smart uses the same three-zone model but with:
- Rate-of-change awareness: if temp is rising, boost fan speed proportionally to the rate
- Calibration data: the adaptive intensity finder discovers the machine's thermal response, and calibration maps how each fan speed handles proportional load
- Without calibration: conservative S-curve (already built, stays as fallback)

- Temperature anomaly logging with process capture (already built: >10°C in 30s)

### Build order

1. Redesign FanProfile model — add curve parameters (startTemp, ceilingTemp, stopTemp, maxRPMPercent)
2. Add ramp-up governor to ThermalMonitor (~400 RPM/sec)
3. Implement proportional curve in ThermalMonitor.tick() for Balanced/Performance
4. Implement Silent as hands-off with 78°C intervention
5. Redesign Smart to use same curve model with rate-of-change and calibration
6. Update calibration to work with new curve parameters
7. Add fan speed change logging
8. Update all documentation (README, ROADMAP, in-app text)
9. Audit and debug
10. Test on M5 Max
11. Test on Mac Studio and M1 Max

---

## Planned Features

### Calibration (Research Tool)

Machine-specific thermal calibration for the Smart profile. Currently available as a CLI-only research command (`sudo thermalforge calibrate`). The stress infrastructure (Metal compute + CPU stress with adaptive intensity) is built and functional — it can spike CPU and GPU load to measure thermal response.

The calibration methodology needs further research to produce data that meaningfully improves Smart's default curve. The fan control industry does not typically pre-calibrate — they use proportional curves with runtime adaptation, which is what Smart already does.

Future direction: runtime learning during normal use, where Smart observes the relationship between fan speed and temperature response during real workloads and refines its curve over time.

### Runtime Learning

During normal use, Smart observes how the machine responds to fan speed changes. Over time, it learns machine-specific thermal characteristics without any stress test. This produces better data than synthetic calibration because it reflects real workloads.

### Enhanced Logging

Additional data points for research-grade logging:

- **Thermal throttle state** — `ProcessInfo.thermalState` (nominal/fair/serious/critical) and `com.apple.system.thermalpressurelevel` (5 levels). Captured at every sample.
- **Power draw** — SMC power keys (PSTR, PCPT, PCPG) for package and per-domain wattage.
- **GPU utilization** — Metal performance statistics or IOKit GPU activity.
- **Memory pressure** — system memory pressure percentage.
- **Delta-T over ambient** — temperatures as both absolute °C and delta above ambient. Standard comparison metric (Gamers Nexus, Notebookcheck, Jarrod's Tech).
- **User markers** — `thermalforge mark "started render"` inserts annotated timestamp into active session.
- **Statistical summary** — min, max, mean, std dev, P95, P99 for all sensors. Time in each thermal state. Peak fan RPM.

Sources: Gamers Nexus methodology, Notebookcheck stress tests, NASA MIL-STD-1540E, Apple WWDC 2019 Session 422.

### Experiment Mode

Controlled thermal testing framework. No existing macOS tool offers this.

```bash
thermalforge experiment --workload cpu --fan smart --duration 10m --label "smart-baseline"
thermalforge experiment --workload gpu --fan 75%  --duration 10m --label "gpu-fixed-75"
thermalforge compare smart-baseline gpu-fixed-75
```

- Built-in workloads: CPU, GPU (Metal compute), CPU+GPU combined, idle baseline
- Custom command as workload
- Automatic baseline capture (5 min idle before/after)
- Steady-state detection (<0.5°C over 2 minutes)
- Throttle detection with exact timestamps
- A/B comparison reports with statistical significance
- Delta-T over ambient

Sources: Gamers Nexus, Notebookcheck, Jarrod's Tech, Phoronix Test Suite, NASA/JEDEC.

### Community Thermal Database

Opt-in anonymous upload of experiment results. Modeled after OpenBenchmarking.org.

- Anonymous machine fingerprinting (chip + core count + fan count, never serial number)
- Standardized experiment profiles for cross-machine comparison
- Delta-T over ambient as comparison metric
- "Compare my machine" queries
- Community validation and outlier detection
- Local-first: all data stored locally, upload always opt-in

### Update Notifications

Lightweight version check on app launch.

- Hit GitHub releases API, compare against running version
- Show "Update available" in menu bar dropdown with link
- Non-intrusive — no popups
- Homebrew: `brew upgrade thermalforge`
- Future: Sparkle framework for in-place auto-update (requires Xcode project)

### SEO / AI Discoverability

- GitHub topics set (18 topics)
- Repo description keyword-optimized
- README structured for AI extraction
- Consider: GitHub Discussions, blog post, landing page

### Other

- **Control Center widget** — requires Xcode project + WidgetKit
- **FORGE process auto-detection**
