# Backlog

Open items that deliberately did not ship in 0.2.0. Each is recorded with the reason it waits.

## Overheat protection

- **Automatic release at 15 min (safety cap).** Once the system enters reduced performance, force a release after 15 minutes regardless of temperature. *Why it waits:* the cap must respect Apple's own thermal throttle window — the "reduce while hot" contract of the setting has not been documented by Apple yet; the spec in POWERMODE-PLAN.md is a draft, and the constant (15 min) is unvalidated. Until that's nailed down, the guard is pure hysteresis, which has proven stable in field use.
- **Move the guard into the daemon.** Today protection lives in the app process: quit the app → protection off (Apple's stock thermal management still runs underneath). A daemon-side guard would survive app restarts and cover launch gaps. *Why it waits:* the daemon protocol has no pmset surface yet and the current risk window (app not running) is acceptable for a 0.x release.
- **Battery-optimized thresholds.** The 88/70 defaults are tuned for AC. On battery, a lower reduce threshold (less power draw → battery preserved and passive cooling aided) and/or different hysteresis may be better. *Why it waits:* needs field data from battery sessions; the feature works on battery, the tuning just isn't validated.
- **Throttle-state input.** Use `ProcessInfo.thermalState` (or SMC throttle flags) to engage/reduce *while Apple is throttling* rather than on raw temperature — i.e. "reduce only when the chip is actually losing performance." Overlaps with the "thermal throttle state" logging item; ship together once the logging side lands.

## GUI

- **Smart button: selected-LED column alignment.** (0.2.1 review) The leading checkmark on the Smart button does not sit exactly on the same column as the four picker rows' checkmarks. Three compounding causes: the `.bordered` button's chrome/internal padding insets its content; the quick-actions row centers content in a half-width button; and the picker's checkmark column is system-owned and not addressable. True parity would require restyling Smart from a button into a full-width borderless menu row (asymmetric next to the Default button). **Decision: keep as-is** — the orange LED is unambiguous; a magic-padding workaround would break across macOS versions. Revisit if the quick-actions row is ever redesigned.

## Decisions (closed, kept for the record)

- **No engage/release debounce in the guard.** (0.2.0 review) Rapid mode flapping on oscillating temperature is *expected behavior*, user-tunable via the thresholds — not a defect to smooth over. Deliberately not implemented.
- **Guard is app-side for 0.2.0.** Accepted trade: protection stops if the app quits; Apple stock thermal management remains the permanent backstop.
- **Thresholds are a GUI-managed setting** (`defaults com.thermalforge.app`), not a setup-script argument — users re-tune per workload, and the GUI is the supported surface.

- [ ] (possible) Flapping on bursty workloads: both hysteresis directions act on a
  single 100ms sample. On bursty load (e.g. compiles: 90°C for seconds, then 65°C
  gaps) the mode can flap reduced↔high in sync with the load. Arm-on-one-sample is
  a deliberate safety decision (keep); if flapping annoys, add a short sustained
  requirement to the RESTORE direction only.
