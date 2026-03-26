# ThermalForge Roadmap

## Smart Profile — Proactive Thermal Curve (Coming Soon)

A new default profile that keeps Apple Silicon chips running at peak sustained performance by getting ahead of heat instead of reacting to it.

### The problem with reactive cooling

Apple's default fan behavior and traditional fan control apps wait until temperatures are already high before ramping fans. This creates a damaging cycle:

1. Heavy workload starts (render, LLM inference, compile)
2. CPU/GPU runs at full clocks, heat builds unchecked
3. Temps hit ~90°C — chip starts throttling clock speeds, performance drops 10-20%
4. Fans finally ramp up reactively
5. Temps drop, clocks recover, fans slow down
6. Heat builds again — repeat

This sawtooth pattern hurts performance (sustained throughput loss), hurts hardware longevity (thermal cycling stress on solder joints and interconnects — the damage metric is temperature swing amplitude, not absolute temperature), and forces fans to work harder than they need to because they're always recovering from a heat spike instead of preventing one.

### How the Smart profile works

Instead of threshold triggers ("hit 80°C → set fans to 85%"), the Smart profile uses a graduated curve that starts early and ramps smoothly:

| Temp Range | Fan Behavior | Rationale |
|---|---|---|
| Below 60°C | Apple default | No thermal concern |
| 60–75°C | Gentle ramp begins | Get ahead of rising heat before it compounds |
| 75–85°C | Moderate, steady ramp | Target steady state — full boost clocks, zero throttling |
| 85–90°C | Aggressive ramp | Approaching throttle onset (~90°C on Apple Silicon) |
| 90°C+ | Max fans | Chip is losing performance — cool down immediately |

The goal is to hold temps in the 75–85°C range under sustained load. This is the sweet spot: full performance, no throttling, and fans at moderate speeds because they never have to recover from a thermal spike.

### Why this is better for hardware longevity

Research in semiconductor reliability (Coffin-Manson model) shows that thermal cycling — repeated large temperature swings — accelerates solder joint fatigue and interconnect failure. A chip held stable at 78°C is under less mechanical stress than one swinging between 50°C and 95°C, even though the sawtooth has a lower average temperature. Proactive cooling reduces delta-T, which directly extends component lifespan.

### Why Apple doesn't do this

Apple optimizes for the majority of users who value silence and battery life over sustained peak performance. In a store demo, quiet = premium. For rendering, AI compute, compiles, and sustained workloads, that tradeoff costs real performance. ThermalForge gives power users the choice Apple doesn't.

### UI changes

**Current:**
- Profiles: Silent, Balanced (CPU>70°), Performance (CPU>80°), Max
- Buttons: [Max] [Auto] ← "Auto" is misleading, just resets to Apple defaults

**Proposed:**
- Profiles: **Smart (recommended)**, Silent, Balanced, Performance, Max
- Buttons: [Max] [Reset to Default] ← clearly hands control back to Apple
- Smart profile documentation accessible from the app explaining why it's recommended

### Build plan

1. Implement graduated fan curve in ThermalMonitor — smooth RPM calculation based on temp range, not threshold jumps
2. Determine optimal RPM-to-temperature mapping per machine (fans have different ranges across MacBook Pro vs Mac Studio)
3. Add Smart profile to FanProfile with the curve parameters
4. Rename "Auto" button to "Reset to Default" in MenuBarView
5. Make Smart the default selected profile for new installs
6. Validate with thermal logging data — compare sawtooth (reactive) vs flat-line (proactive) under identical workloads

---

## Thermal Logging (Coming Soon)

Research-grade thermal data export for Apple Silicon Macs. Designed for reproducible analysis — arXiv papers, hardware engineering, cross-machine comparison.

### Output

Each session produces a self-contained folder:

```
thermalforge_log_<timestamp>/
  metadata.json     — machine, chip, OS, ThermalForge version, fan profile, data dictionary
  thermal.csv       — timestamp, smc_key, category, value_c, fan0_rpm, fan1_rpm, fan_mode, profile
  processes.csv     — timestamp, pid, name, cpu_pct, gpu_pct
```

### CLI

```bash
thermalforge log                                  # 1Hz, auto-delete after 24h
thermalforge log --rate 10 --duration 1h          # 10Hz for 1 hour
thermalforge log --rate 1 --no-expire --output .  # persistent, custom location
```

### What gets captured

**Every sample (at configured rate):**
- All detected temperature sensors (raw SMC key + category + °C)
- Fan state: actual RPM, target RPM, mode (auto/manual), active profile
- Top 5 processes by CPU and GPU utilization
- Power draw (if SMC power keys available)

**Session metadata (once at start):**
- Machine model identifier (e.g., Mac17,7)
- Chip (e.g., Apple M5 Max)
- Core count (P-cores, E-cores, GPU cores)
- macOS version
- ThermalForge version
- Fan profile active at session start
- Data dictionary: every SMC key found on this machine with type, size, category, unit
- Sample rate and duration configured

**Session integrity:**
- Total sample count
- Start/end timestamps
- Gap detection (sleep/wake events flagged)

### Design decisions

- **CSV + JSON sidecar** — no custom formats, loadable in pandas/R/Excel without a parser
- **Raw SMC key names** — no friendly labels that could be wrong across chip generations
- **Category column** — prefix-based (TC/Tp = cpu, TG/Tg = gpu, etc.) for cross-machine filtering
- **Auto-delete default (24h)** — prevents disk bloat for casual users; `--no-expire` for researchers
- **Fixed sample rate** — precise timing, not "roughly every N seconds"
- **Process snapshots** — what was running when temps changed, the missing link in every other thermal tool

### Build plan

1. Sampling engine — precise timer, collects all sensor + fan data per tick
2. Process snapshot — read top N processes by CPU/GPU at each sample
3. Power probing — discover and read SMC power keys (PSTR, PCPT, etc.)
4. Metadata collector — machine model, chip, core count, OS, data dictionary
5. CSV writer — streaming writes, not buffered (safe against crashes/kills)
6. Session management — start/stop, gap detection, auto-cleanup
7. CLI integration — `thermalforge log` command with rate/duration/output/expire flags

---

## In-App Calibration UI (Planned)

Currently calibration runs via `sudo thermalforge calibrate` in the terminal. The planned in-app experience:

### UI

A dedicated calibration window accessible from the menu bar dropdown. Shows:
- **Progress bar** with time elapsed and estimated time remaining
- **Current phase** — which fan speed level is being tested, heating or cooling
- **Live temperature** — real-time readout during the test
- **Stop button** — immediately resets fans to Apple defaults, exits cleanly, Smart falls back to the default curve

### Behavior

- First time a user clicks Smart with no calibration data: prompt to calibrate with an option to skip (Smart uses default curve if skipped)
- Calibration requires elevated privileges — app prompts for password once
- If stopped early: no partial data saved, Smart uses default curve
- If ThermalForge quits mid-calibration: same as stopping — fans reset via daemon, no data saved
- On completion: calibration data saved permanently, Smart immediately starts using it

---

## Other planned features

- **Control Center widget** — requires Xcode project + WidgetKit
- **FORGE process auto-detection**
