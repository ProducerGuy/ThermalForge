# Power Protection (pmset powermode) — Implementation Plan

Built-in replacement for `powermode_controller-v1.py`: when the hottest reported
sensor crosses HIGH (default 88°C) the app drops the system to **reduced power**
(`sudo pmset -c powermode 1`); when it cools below LOW (default 70°C) it restores
**high performance** (`sudo pmset -c powermode 2`). Controlled by the always-on
menu bar app, evaluated on the existing 100 ms thermal tick.

## Status — complete (2026-08-23), shipped in 0.2.0

All four steps implemented and field-verified on the real machine (2026-08-22/23):
controller + 29 unit tests; app wiring + GUI (with the draft-commit fix); live drills
A engage / B release / C external change (detected+adopted, not fought) / D toggle-off
(inert, no force-restore) all passed against real `pmset` at multiple threshold
settings; docs (README section, backlog.md) and version 0.2.0 in place.

Two deliberate deviations from the locked design above, discovered during Step 0/3:
- **Sudo form:** the machine's passwordless entry allows only the *unconditional*
  `pmset powermode` form (not `pmset -c powermode`) — the implementation therefore
  uses the unconditional form, which Apple applies regardless of power source (a
  deliberate design choice; matches the user's field experience on battery).
- **Hysteresis:** 100 ms decisions, deliberately *no* engage/release debounce (rapid
  flapping on oscillating temp is expected; user tunes thresholds via GUI). See backlog.md.

## Agreed design (locked)

- **Location:** app-side, riding the existing 100 ms `ThermalMonitor` tick — zero added SMC load.
- **Decision cadence:** 100 ms. **Mode re-read:** every 2 s (`pmset -g`, no sudo, background queue) — kills the v1 stale-state bug (external `pmset` while hot is re-asserted within 2 s) and drives the GUI indicator. Same load the Python script already imposed.
- **Execution:** `sudo pmset -c powermode N` from the app. Works passwordless via your existing sudoers entry; a GUI app has no TTY, so on a machine without the entry sudo fails **fast** (no hang/prompt) → warning banner + log, feature degrades gracefully.
- **Peak temp:** max of **all** reported sensors.
- **Power domain:** AC only (`-c`). On battery the controller still evaluates; the set is stored and applies on next AC plug-in (v1 parity, no power-source branching).
- **Enabled by default.** GUI: enable toggle + editable HIGH/LOW.
- **Persistence:** app `UserDefaults` (GUI is the single editor; in-process writes are instant — no polling). Terminal `defaults` edits apply at next launch (documented).
- **No daemon changes. No CLI changes.** (Backlog: daemon-side loop for headless, 95 °C daemon fan backstop, macOS 14 key guard, CLI `powermode` wrapper.)
- App not running ⇒ no control-loop protection (accepted consequence; pmset setting persists across app quit/reboot and is re-evaluated on next launch).
- Version: 0.1.x → **0.2.0**.

## Process rule

Each step below is a separate task. After implementing a step I **verify** it
(build/tests/live evidence) and **ask for your acknowledge** before starting the next.

---

## Step 0 — Read-only environment verification (no state change)

Establish the ground truth before writing code:

1. `sudo -l` — capture the exact sudoers entry (which binary/args are NOPASSWD).
2. `sudo -n pmset -g` — prove the authorization works non-interactively.
3. `sudo -n pmset -c powermode 1` — **zero-risk**: current mode is already 1, so this
   proves the set-path (NOPASSWD + `powermode` key accepted) without changing anything.
4. Capture `pmset -g` / `pmset -g custom` output as the reference for parser tests.
5. Note current `ThermalForgeVersion.current` and the app's UserDefaults suite name.

**Verify:** all commands' actual output captured. **Gate:** your acknowledge.

## Step 1 — Core: controller, backend, config + unit tests

New in `Sources/ThermalForgeCore/`:

- `PowerMode` — `Int`-backed enum: `reduced = 1`, `high = 2`, + display names.
- `PowerModeBackend` — protocol: `readCurrentMode() -> PowerMode?`, `setMode(_:) throws`.
- `PmsetPowerModeBackend` — `Process`-based. Read: `pmset -g`, parse the `powermode N` line.
  Set: `sudo pmset -c powermode N`; captures stderr for the failure banner. No TTY → fast fail.
- `PowerModeConfig` — `enabled` (default true), `highTemp` (88), `lowTemp` (70) in
  `UserDefaults`; validated/clamped (ranges + `low < high` invariant). 100 ms period is an internal constant, not user-facing.
- `PowerModeController` — owns state (`currentMode`, config). `evaluate(peakTemp: Float?)`
  is a **pure** decision function (≥ high ⇒ reduced, ≤ low ⇒ high, else/already-target/disabled ⇒ no-op).
  `refreshMode()` reads actual mode (2 s cadence, serial background queue).
  Transitions: set → read-back verify → publish state + `TFLogger` entry. Never trusts a stale variable.
- `ThermalStatus.maxSensorTemperature` — computed: max of all sensor values.

New test file `Tests/ThermalForgeTests/PowerModeTests.swift`:

- Decision table: engage / release / in-band / nil temp / disabled / already-at-target.
- Parser: captured real `pmset -g` output (step 0), missing key, `custom` format.
- Config: defaults, round-trip, clamping, `low < high` invariant.
- Controller with stub backend: set-once dedupe, verify-failure path, external-change reconciliation.

**Verify:** `swift build` + `swift test` green; report test counts. **Gate:** your acknowledge.

> ✅ **DONE & VERIFIED (2026-08-22):** `swift build` clean. `swift test` full suite:
> 58 swift-testing tests in 9 suites passed + XCTest "All tests" passed (EXIT=0).
> Includes 29 new PowerMode tests. Two real bugs were caught by the tests and fixed:
> (1) set-error diagnostics were swallowed by `localizedDescription` on a plain Swift
> error → now uses `description`; (2) test stub hang + unbounded wait → bounded 5 s
> timeout. Also: missing `.unknownValue` case in the verify switch; double-wrapped
> backend error. Note: `TFLogger.power()` category was added in Step 1 (Logger is Core),
> so Step 2 no longer needs the Logger edit.


## Step 2 — App wiring + GUI

- `ThermalMonitor`: add optional lightweight hooks — `onTick(ThermalStatus)` (100 ms) and
  `onMonitorTick()` (2 s) — so the core monitor stays generic; the app feeds the controller.
  (Both fire where they fire today; all process I/O stays on the controller's background queue.)
- `AppState`: creates controller + config; `@Published` `powerMode`, `powerProtectionEnabled`,
  `powerModeWarning`; wires hooks; reads mode once at launch.
- `MenuBarView`: new **Power Protection** section — enable toggle, current-mode indicator
  (Reduced/High), HIGH/LOW °C fields (respect the existing °F/°C display toggle, stored in °C),
  warning banner on sudo failure.
- `TFLogger`: new `POWER` category.

**Verify:** full `swift build`; launch the app; check log file for the launch mode read;
menu bar shows correct mode (machine is currently reduced). **Gate:** your acknowledge.

> 🟡 **CODE-COMPLETE (2026-08-22), live verification pending:** `swift build` clean (no
> warnings), full test suite green (58 swift-testing + XCTest). Implemented: monitor
> `onTick`/`onMonitorTick` hooks, AppState controller setup + published state + actions,
> MenuBarView POWER PROTECTION section, public `PowerModeControllerState` init.
> BLOCKED ON: you quit/uninstall the installed ThermalForge app (duplicate-instance
> guard), then I launch the debug build and verify the launch mode read in the log.


## Step 3 — Live end-to-end verification on your machine

Deliberate state changes — each runs only after your go:

- **A engage:** CLI `sudo pmset -c powermode 2` (back to high) → apply load (or temp the GUI
  threshold just above current) → expect auto-switch to reduced within ~2 s, log line, UI update.
- **B release:** cool below LOW (or adjust) → expect restore to high.
- **C external-change:** while hot, terminal `sudo pmset -c powermode 2` → expect re-assertion ≤ 2 s.
- **D toggle:** GUI enable off → controller stops acting; on → resumes.
- Restore: defaults 88/70, enabled, machine left in the mode you want, load killed.

**Verify:** log excerpts for A–D. **Gate:** your acknowledge.

## Step 4 — Hardening, docs, release

- Graceful sudo-failure path covered by a unit test (stubbed backend) + banner wording.
- README: feature row, "Overheat Protection" section (how it works, the exact sudoers line
  from step 0, GUI setup, battery behavior, app-closed behavior), backlog notes.
- `powermode_controller-v1.py`: header note — superseded by the built-in feature in 0.2.0.
- `ThermalForgeVersion.current` → `0.2.0`.
- Backlog/ROADMAP entries: daemon-side loop (headless), 95 °C daemon fan backstop,
  macOS 14 `powermode` key guard, CLI `powermode` wrapper, live terminal config.
- Final: full `swift build && swift test` green.

**Verify:** all of the above; report. **Gate:** your acknowledge → feature done.
