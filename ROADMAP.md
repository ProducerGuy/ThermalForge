# ThermalForge Roadmap

## Built Features

### Smart Profile (Built)

Proactive thermal curve that monitors temperature velocity and ramps fans before throttling occurs. Targets 85°C ceiling. Works with or without calibration — default conservative S-curve without data, machine-specific curve with calibration.

- Graduated continuous curve from 60°C (floor) to 85°C (ceiling)
- Rate-of-change awareness: ramps harder when temp is rising, eases off slowly when falling
- Uses calibration data (maxSustainableLoad per fan level) when available
- Falls back to conservative defaults when no calibration exists
- Ramp-down governor prevents sawtooth oscillation

### Calibration (Built)

Machine-specific thermal profiling. Gradually increases CPU+GPU load (Metal compute + CPU stress) at each fan speed level, measuring what each fan speed can handle below 85°C.

- Load steps: 5% → 10% → 15% → 25% (targeting ~1°C/sec realistic ramp rates)
- Pre-calibration cooldown: waits for machine to reach <45°C baseline
- Records ambient temperature from SMC sensors
- Fan spin-up wait (5s) before sampling at each level
- Transition noise discard (6s) at each load step change
- Three modes: Quick (~14 min), Standard (~32 min), Optimized (until stable, ~35-50 min)
- CPU+GPU combined, CPU only, or GPU only stress types
- Downgrade prevention: Quick can't overwrite Standard or Optimized
- In-app UI: mode picker, progress bar, live temp, stop button
- CLI: `sudo thermalforge calibrate --mode quick --stress combined`
- CSV log of every sample for research use

### Thermal Logging (Built)

Research-grade data export: `thermalforge log`

- CSV with all temperature sensors, fan RPM (actual + target), fan mode per sample
- Process CSV: top 5 processes by CPU at every sample
- JSON metadata: machine, OS, sensor dictionary, session info
- Configurable rate (1-10 Hz), duration, output directory
- Auto-delete after 24h by default, `--no-expire` for researchers

### Safety Systems (Built)

- 95°C safety override: forces max fans regardless of profile
- Heartbeat watchdog: daemon resets fans if app dies (15s timeout)
- Clean state on app launch: fans reset to auto before any profile activates
- Clean shutdown: fans reset on normal app quit
- SMC lock: serializes all fan control operations across daemon threads
- Duplicate instance prevention
- Calibration data validation: rejects physically impossible data
- Error logging to ~/Library/Logs/ThermalForge/thermalforge.log

### In-App Calibration UI (Built)

- Mode picker (Quick/Standard/Optimized) in menu bar dropdown
- Smart button prompts calibration if no data exists, with Skip option
- Progress bar, current phase, live temperature during calibration
- Stop button: kills stress, resets fans, resets profile to Silent
- Calibration complete auto-activates Smart

---

## Planned Features

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
