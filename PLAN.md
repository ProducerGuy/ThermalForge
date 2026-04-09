# Profile Redesign Build Plan

## Infrastructure Change: Dual-Cadence Tick

**`ThermalMonitor.swift`** — split the single 2s tick into two cadences:

| Cadence | Interval | What It Does |
|---|---|---|
| **Thermal tick** | 100ms | Read temps, calculate curve, apply ramp governor, write fan speed |
| **Monitor tick** | Every 20th thermal tick (2s) | Process capture, anomaly detection, history logging |

New state: `private var tickCounter: Int = 0` — increments every thermal tick, runs monitor logic when `tickCounter % 20 == 0`.

## Architecture Change: Per-Profile Personality

**`Profile.swift`** — add to `Curve` struct:

```swift
enum CurveShape { case linear, easeIn, easeOut, sCurve }

let curveShape: CurveShape          // how targetPercent maps temp to speed
let rampUpPerSec: Float             // max fan speed increase per second (0.0-1.0)
let rampDownPerSec: Float           // max fan speed decrease per second
let sustainedTriggerSec: Float      // seconds above startTemp before engaging
let instantEngage: Bool             // skip ramp-up entirely (MAX)
```

`targetPercent()` updated to apply curve shape:
- **easeIn**: `pos² * maxRPM` — quiet start, accelerates
- **linear**: `pos * maxRPM` — current behavior
- **easeOut**: `√pos * maxRPM` — fast start, levels off
- **sCurve**: `pos² * (3 - 2*pos) * maxRPM` — smooth both ends

---

## Profile Definitions

### Silent (Apple Default)
No changes. Hands-off monitoring only. Apple controls fans.

### Balanced — "Everyday, keep it quiet"
| Parameter | Value | Rationale |
|---|---|---|
| Stop | 50°C | Same as Apple's observed off range |
| Start | 55°C | 5°C hysteresis |
| Ceiling | 70°C | Reaches max fan speed at 70°C |
| Max fan | 60% | Caps noise |
| Curve shape | **Ease-in** (`pos²`) | Quiet at low temps, ramps faster as heat builds |
| Ramp up | ~400 RPM/s | Gentle, not jarring |
| Ramp down | ~200 RPM/s | Smooth deceleration |
| Sustained trigger | **8 seconds** | Filters all transients — this profile prioritizes quiet |

Balanced is the "don't bother me" profile. It accepts higher temps in exchange for less fan noise. The ease-in curve means at 60°C you're barely hearing the fans; at 65°C+ they start pulling harder.

### Performance — "Keep it cool, noise is fine"
| Parameter | Value | Rationale |
|---|---|---|
| Stop | 50°C | Unified off threshold |
| Start | 55°C | Same start, but faster response |
| Ceiling | 65°C | Reaches max speed 5°C earlier than Balanced |
| Max fan | 85% | High but not ear-splitting |
| Curve shape | **Linear** | Direct, proportional, responsive |
| Ramp up | ~800 RPM/s | 2× Balanced — gets to cooling faster |
| Ramp down | ~300 RPM/s | Moderate deceleration |
| Sustained trigger | **4 seconds** | Filters brief spikes but responds to real work quickly |

Performance is for compiles, renders, LLM inference. It doesn't wait around. Linear curve means the cooling response is proportional and predictable. 85% cap because 100% on these fans is loud and the last 15% of RPM gives diminishing thermal returns.

### Max — "Attack dog"
| Parameter | Value | Rationale |
|---|---|---|
| Stop | 50°C | Unified off threshold |
| Start | **65°C** | Higher start because the response is instant — no need to engage early |
| Ceiling | N/A | No curve — it's binary |
| Max fan | 100% | Full send |
| Curve shape | N/A up / **S-curve down** | Instant on, gentle off |
| Ramp up | **Instant** | Single reading above 65°C sustained → 100% immediately |
| Ramp down | ~200 RPM/s with S-curve | Give temps time to stabilize |
| Sustained trigger | **5 seconds** (50 ticks at 100ms) | Filters transient spikes but still catches real events |

**Up behavior**: `sustainedAboveCount >= 50 && peakTemp >= 65` → instant `setMax()`. No ramp governor. They spike, we spike.

**Down behavior**: Once temp drops below 65°C, S-curve governor ramps down at ~200 RPM/s. Below 50°C with rate-of-change ≤ 0 → fans off.

**Why this fixes the logs**: The Apr 7 22:12 event hit 56°C at tick 1, then 72°C at tick 2. With Option C at 65°C, the 72°C reading (2 seconds later) would have instantly triggered 100% fans. Instead of waiting for safety override at 98°C, fans would have been at 7800+ RPM 26°C earlier.

### Smart — "Proactive adaptive"
| Parameter | Value | Rationale |
|---|---|---|
| Stop | 50°C | Unified off threshold |
| Start | 53°C | 2°C earlier than others — gets ahead of rising temps |
| Ceiling | 85°C | Wide range for proportional control |
| Max fan | 100% | Uncapped when needed |
| Curve shape | **S-curve** | Smooth across the full range (existing) |
| Ramp up | Adaptive (rate-of-change based) | Existing logic — faster when temps rising fast |
| Ramp down | ~200 RPM/s | Smooth deceleration |
| Sustained trigger | **6 seconds** (60 ticks) | Proactive but filtered |

Smart keeps its existing rate-of-change awareness and calibration data support. The main improvements it gets are the 100ms tick (10× smoother fan transitions) and the non-linear curve shapes.

---

## Files to Modify

| File | Changes |
|---|---|
| **Profile.swift** | Add `CurveShape` enum, add ramp/trigger/shape fields to `Curve`, update `targetPercent()` for curve shapes, update all 5 profile definitions, update `Codable` conformance |
| **ThermalMonitor.swift** | 100ms tick with monitor cadence at 2s, per-profile ramp rates from `Curve`, per-profile sustained trigger from `Curve`, MAX-specific instant engage path, remove hardcoded `maxRampUp`/`maxRampDown`/`sustainedTriggerCount` |
| **ProfileTests.swift** | Update all threshold/parameter tests, add curve shape tests, add per-profile ramp rate tests, add MAX instant-engage test, add sustained trigger per-profile tests |
| **MenuBarView.swift** | Update labels — MAX shows "65°C instant", others show start→ceiling range |

## What Will NOT Change
- Safety override (95°C) — working correctly, stays as-is
- Anomaly detection — working, just moves to 2s cadence
- Process capture — working, stays at 2s cadence
- Smart rate-of-change logic — working, just benefits from faster tick
- Calibration system — unchanged
- Silent profile — unchanged
- Daemon/heartbeat/SMC layer — unchanged
