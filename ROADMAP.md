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

## In-App Calibration UI (Built)

Calibration is accessible from both the terminal (`sudo thermalforge calibrate`) and the menu bar app. The app shows:
- **Progress bar** with time elapsed
- **Current phase** — which fan speed level is being tested, heating or cooling
- **Live temperature** — real-time readout during the test
- **Stop button** — immediately resets fans to Apple defaults, exits cleanly, Smart falls back to the default curve

---

## Enhanced Logging (Planned)

Additional data points for research-grade logging:

### New data columns
- **Thermal throttle state** — `ProcessInfo.thermalState` (nominal/fair/serious/critical) and `com.apple.system.thermalpressurelevel` (5 levels including the hidden moderate/heavy distinction that `.fair` masks). Captured at every sample.
- **Power draw** — SMC power keys (PSTR, PCPT, PCPG, etc.) to capture package and per-domain wattage. Direct correlation between power and thermal output.
- **GPU utilization** — Metal performance statistics or IOKit GPU activity to capture GPU load alongside CPU processes.
- **Memory pressure** — system memory pressure percentage via Mach VM stats. Already implemented in ThermalMonitor, needs to be added to the logger.
- **Delta-T over ambient** — accept ambient temperature input (manual or via TA0P/TAOL sensor if present), report all temps as both absolute °C and delta above ambient. Delta-T is the standard comparison metric in hardware review methodology (Gamers Nexus, Notebookcheck, Jarrod's Tech).
- **User markers** — `thermalforge mark "started render"` command that inserts an annotated timestamp into the active log session. Enables post-hoc correlation between events and thermal data.
- **Statistical summary in metadata.json** — min, max, mean, standard deviation, P95, P99 for all sensors. Total time in each thermal state. Peak fan RPM. Time at or above throttle threshold.

### Sources informing this design
- Gamers Nexus cooler testing methodology: five averaged sets of averages, automated standard deviation monitoring
- Notebookcheck: 60 min idle + 60 min load, ambient-controlled
- NASA MIL-STD-1540E: thermal stability = rate of change <1°C over 5 hours
- Apple WWDC 2019 Session 422: thermal state simulation and monitoring

---

## Experiment Mode (Planned)

Controlled thermal testing framework. No existing macOS tool offers this.

### CLI interface

```bash
thermalforge experiment --workload cpu --fan smart --duration 10m --label "smart-baseline"
thermalforge experiment --workload gpu --fan 75%  --duration 10m --label "gpu-fixed-75"
thermalforge experiment --workload combined --fan max --duration 10m --label "worst-case"
thermalforge experiment --workload idle --duration 5m --label "idle-baseline"
thermalforge experiment --workload "blender --render scene.blend" --fan smart --duration 30m --label "real-render"
thermalforge compare smart-baseline gpu-fixed-75 worst-case
```

### Built-in workloads
- **cpu** — saturate all P-cores and E-cores with compute-bound work (similar to Prime95 small FFTs)
- **gpu** — Metal compute shaders that stress the GPU pipeline (inspired by Philip Turner's metal-benchmarks)
- **combined** — CPU + GPU simultaneously. The real-world worst case for Apple Silicon where CPU, GPU, and Neural Engine share the same die and unified memory.
- **idle** — no workload, machine at rest. Used as baseline before/after active tests.
- **Custom command** — any shell command as the workload. Run your actual renders, compiles, or ML inference.

### Experiment protocol (modeled after Gamers Nexus and Notebookcheck)
1. **Baseline capture** — 5 min idle measurement at the start (configurable)
2. **Workload phase** — run the specified workload for the specified duration
3. **Steady-state detection** — automatic detection when temperature stabilizes (rate of change <0.5°C over 2 minutes). Reported as time-to-steady-state.
4. **Throttle detection** — monitor `com.apple.system.thermalpressurelevel` and record exact timestamps of state transitions. Report time-to-throttle.
5. **Cooldown capture** — 5 min idle measurement after workload ends
6. **Full logging throughout** — every data point captured to CSV (thermal, processes, power, throttle state)

### Metrics per experiment
- **Time-to-throttle** — seconds from workload start until thermal state changes from nominal
- **Time-to-steady-state** — seconds until temperature stabilizes under load
- **Peak temperature** — highest reading during the test
- **Steady-state temperature** — average temp after stabilization
- **Delta-T over ambient** — all temps reported as degrees above ambient
- **Statistical summary** — mean, std dev, min, max, P95, P99 for all sensors
- **Thermal state timeline** — exact timestamps of every state transition

### Comparison reports

`thermalforge compare` generates:
- Side-by-side statistical summaries
- Delta between experiments (e.g., Smart held 7°C lower than fixed 75%)
- Time-to-throttle comparison
- Identification of statistically significant differences
- Export as CSV or formatted text

### Use cases
- **Thermal pad modders** — run the same experiment before and after a mod, get a quantified comparison instead of "it feels cooler"
- **Developers** — profile how your app affects system thermals under controlled conditions
- **Hardware reviewers** — standardized methodology with reproducible results
- **Cooling solution engineers** — compare thermal resistance across configurations
- **ML researchers** — measure sustained inference throughput under different thermal strategies

### Sources informing this design
- Gamers Nexus: single die, ambient-controlled, Delta-T-over-ambient, noise-normalized at 35 dBA, five averaged sets
- Notebookcheck: 60 min idle + 60 min load, Prime95 + FurMark, Fluke T3000 validation
- Jarrod's Tech: controlled 21°C ambient, 3x 10-min Cinebench averaged
- Phoronix Test Suite: 450+ test profiles, concurrent stress runs, community result sharing
- NASA/JEDEC: formal stabilization criteria for thermal testing

---

## Community Thermal Database (Planned)

Opt-in anonymous upload of experiment results. Modeled after OpenBenchmarking.org.

- Anonymous machine fingerprinting (chip model + core count + fan count, never serial number)
- Standardized experiment profiles so results are comparable across machines
- Delta-T-over-ambient as the comparison metric
- "Compare my machine" queries — see how your M5 Max ranks against other M5 Max machines
- Community validation — outlier detection, methodology verification
- Local-first: all data stored locally, upload is always opt-in

---

## Update Notifications (Planned)

Lightweight version check on app launch. No auto-install — just awareness.

- On launch, hit GitHub releases API, compare against running version
- If newer version exists, show "Update available (v0.2.0)" in the menu bar dropdown with a link
- Non-intrusive — no popups, no nagging, just a line in the dropdown
- Homebrew users: `brew upgrade thermalforge` handles it
- Source users: link goes to the release page with changelog

Future: Sparkle framework for proper in-place auto-update. Requires Xcode project and code signing.

---

## SEO / AI Discoverability (Planned)

Ensure ThermalForge is found by AI agents (ChatGPT, Claude, Perplexity) and search engines when users search for Mac fan control, Apple Silicon thermal management, or alternatives to Macs Fan Control / TG Pro / AlDente.

- GitHub topics already set (18 topics)
- Repo description keyword-optimized
- README structured for AI extraction (comparison table, feature lists, CLI examples)
- Consider: structured data, GitHub Discussions for community Q&A, blog post or landing page

---

## Other planned features

- **Control Center widget** — requires Xcode project + WidgetKit
- **FORGE process auto-detection**
