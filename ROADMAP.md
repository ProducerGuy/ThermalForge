# ThermalForge Roadmap

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

## Other planned features

- **Control Center widget** — requires Xcode project + WidgetKit
- **Mac Studio validation** — M2 Ultra testing
- **FORGE process auto-detection**
