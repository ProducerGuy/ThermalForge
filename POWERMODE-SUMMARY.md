# Power Mode Feature — Full Summary

*For the project record. Covers requirements → implementation → tests → final status.
Session of 2026-08-23, tree at the pushed PR branch.*

To resume pi coding session: pi --session 01a02559-c407-77d9-847b-2c4fe6b9dbf9

---

## 1. Problem & Objectives

**The hardware reality:** An M5 Pro/Max MacBook under sustained heavy load
(renders, training jobs, builds) can hit **90–105 °C** — inside Apple's
danger zone (throttling territory at 90+). On this machine the **fans alone
cannot hold the temperature**: their curve can't reach the equilibrium the
chip demands.

**Objectives:**
1. A **second line of defense** beyond fans: when temperature crosses a
   threshold, drop the whole system into **reduced performance**
   (`pmset powermode 0`, the System Settings → Battery setting) and restore
   full performance once it cools. Deliberate trade: *reduced performance is
   safe; full performance at an uncontrolled temperature is not.*
2. Tight integration: reuse the app's existing **100 ms thermal sampling**,
   configurable thresholds, visible state, honest warnings.
3. Respect the architecture: the fan **daemon stays untouched** (it remains
   their work); the new logic lives in the app layer, isolated behind a
   protocol so it is testable without hardware.
4. **Upstream-ready:** this work began as a standalone v1 script, was
   productized, and ended as a clean 2-commit PR on the new daemon-architecture
   upstream (rebased, rebased-again after their 0.2.2 release, no conflicts).

## 2. Design Decisions (the five that matter)

| # | Decision | Rationale |
|---|---|---|
| 1 | **No sustained trigger** — a single reading above the high threshold acts immediately | A safety feature with a 6 s "wait to be sure" gate could be 6 s too late; the v1 script (proven in real use) acted on one reading. Hysteresis, not waiting, provides stability. |
| 2 | **Asymmetric rules** — in the danger zone, assert reduced even when the current mode is *unknown*; below the restore threshold, return to high **only if reduced was just verified** | Unknown ≠ safe, so err toward the safe side (re-asserting reduced is idempotent). Unknown below the restore line may well be "already high, never touched" — never force high on a possibly-safe system. |
| 3 | **Verify by read-back** — a set is trusted only after `pmset -g` reports the requested mode | A system that ignores the call (policy lock, etc.) must not be *assumed* reduced. One warning per non-compliance. |
| 4 | **Live truth, not stale state** — refresh re-reads the actual system mode every 2 s | The v1 bug: a manual `pmset 1` during a guard trip was not noticed until the cooldown expired. Now the controller converges on external reality within 2 s and restores cleanly when the machine cools. |
| 5 | **Set rate limits** — 2 s minimum between sets (storm guard) + 30 s backoff after a failed set; 20 °C default hysteresis band (88/70), clamped, user-tunable in their unit | Prevents flapping in a narrow band and hammers a refusing system only once every 30 s. |

Additional choices:
- **Input:** `maxSensorTemperature` — hottest of *all* reported sensors
  (v1 semantics, catches the unreported-sensor regression from the v1 era).
- **Placement:** app-layer, own queue; only published state hops to the main
  actor. The daemon never learns of it.
- **UI:** dedicated **POWER PROTECTION** section (toggle, live mode indicator
  with verified/unverified states, editable thresholds with a "your zone"
  helper), plus warning banners for "sudo refused" and "system didn't apply".
  Menu layout: **Power Protection before Profiles** (fan profile is
  day-to-day tuning; protection is the safety net — order signals intent).
- **Setup:** the `pmset` sudoers entry is **owned by the tool** —
  `install`/`setup.sh` writes it (marker-guarded, atomic 0440, syntax-verified
  with `sudo -n -l`, per-source `-c`/`-b`), `uninstall` removes exactly that
  file. Nothing else about sudo changes.

## 3. Implementation

### Commits (on the pushed PR branch, atop upstream 0.2.2)

```
4a4a68b feat: overheat protection via pmset power mode
d4b961e install/uninstall own the pmset powermode sudoers entry
```

| Area | What landed |
|---|---|
| `PowerMode.swift` | `PowerMode` (high/reduced + display names + 🐇/🐢 symbols) and `PowerModeConfig` (clamping, 2 °C minimum hysteresis gap, `UserPreference`-codable for persistence) |
| `PowerModeController.swift` | The state machine: `processTemperature` / `refresh` / `setEnabled`; storm guard + backoff timers; the asymmetric rules; 2 s live re-read; publishes a value-type snapshot (`PowerModeState`) |
| `PmsetPowerModeBackend` (in the CLI source file) | `sudo -n pmset -c/-b powermode` + read-back, on the controller's queue |
| `ThermalMonitor` | New `onTick` slot — the decision rides the existing 100 ms poll (no extra timer, no extra SMC cost) |
| `FanControl` | New `status` getter — the app now knows the max reported sensor (previously it only had the display temperature) |
| `AppState` | Wires backend + monitor + controller; exposes `power` state; persists the toggle + thresholds; re-arms protection at reboot (the pmset setting survives boot, so does the guard); stops on quit (protection stops with the app; Apple's stock management remains) |
| `MenuBarView` | The Power Protection section, indicator, editable thresholds (user's unit), banners, restore the **Smart checkmark** (leading, reserved space — a regression of the daemon refactor), shorten "System mode" label (drop the truncated "(unprotected)" wording — the orange color carries the signal) |
| `setup.sh` / `install` / `uninstall` | Own the sudoers entry (see above) |
| `PowerModeTests.swift` | 20 tests against a `MockPowerModeBackend` |
| Docs | `POWERMODE-PLAN.md` (design, decisions, test plan), `backlog.md` + entry, `README.md` (tagline, Features, section, FAQs, known-limitations wording), v1 provenance: `powermode_controller-v1.py` kept for reference |

**Scale:** 13 files, +1656/−5 vs. upstream, of which 235 lines of Swift logic
(the rest: menu wiring, docs, tests, plan) and **zero daemon changes**.

### Version strategy
- **Local `main`:** 0.3.1 (your line keeps counting; installed app is 0.3.1).
- **PR branch:** Version.swift reverted to **0.2.2** (upstream value) → the PR
  diff has **no version change**; the maintainer assigns the next version on
  merge. Rule: never push local `main` (0.3.1 line) to the fork.

## 4. Testing

**Unit — 77/77 pass** (57 upstream + 20 new), zero warnings. The new suite
covers the decision rules that matter, including the three regression classes:
- first-cross triggers on a *single* reading; no sustained gate;
- restore only after a verified reduced, never from an unknown state;
- unknown current mode in the danger zone → still asserts (reduced is
  idempotent);
- storm guard (≤1 set per 2 s), 30 s failure backoff, non-compliance warning
  (once, not spammed), config clamping incl. the 2 °C gap rule, and the live
  2 s re-read converging on an externally-set mode.

**Integration (your machine):**
- `./setup.sh` full cycle: sudoers entry written/verified, daemon 0.2.2, app
  with the new section; `sudo -n pmset` silent thereafter.
- **Live behavior:** manual `pmset -c powermode 0` was picked up within seconds
  (the v1 stale-state bug fixed); threshold edits in your unit applied and
  persisted; toggle-off = hands-off in both directions.
- **Load test (final gate):** sustained heavy build — the guard followed the
  curve, dropped to reduced as planned, restored on cooling, no flapping.
  ✅ Approved.
- (On battery the app shows "Fan control unavailable" — the **daemon** never
  runs on battery, upstream behavior; the power guard is the lever there, and
  `pmset -b` is wired for it.)

**Final verification you can still run:**
```bash
git clone git@github.com:<your-fork>/ThermalForge.git tf-pr-test
cd tf-pr-test && git checkout overheat-protection && ./setup.sh
```
(rebuilds exactly what the maintainer will merge; app will report 0.2.2 on
that branch; `rm -rf tf-pr-test` + `setup.sh` from your tree restores 0.3.1)

## 5. Final Status

- **Done:** feature implemented, hardened, tested, load-tested, documented
  (plan, backlog, README), rebased cleanly onto upstream's daemon milestone
  (twice — including the 0.2.2 release day), rebased a third time when they
  shipped the 0.2.2 *release* commit (no conflicts: your files and theirs
  don't overlap).
- **Pushed:** branch `overheat-protection` → your fork (remote `fork`, SSH).
- **PR:** to be created at
  `https://github.com/ProducerGuy/ThermalForge/compare/main...<your-fork>:overheat-protection`
  — title *Overheat protection via pmset power mode*, description closes
  **#41** (Danger Zone Protection — your feature request) and **#27**
  (Smart indicator — checkmark restored).
- **Known open threads (handed to the backlog, not blockers):**
  - #1 upstream gap: daemon has no battery mode (user's issue to file later);
  - #2 upstream has no release notes (ask when convenient);
  - #3 C/D: protection scope — C = "reduced while app is closed" (daemon-side,
    needs maintainer); D = "auto-off on battery" (currently the guard *arms*
    at reboot regardless of power source — acceptable by design, documented).
- **When they merge:** sync the fork, let local `main` take their version
  bump, keep 0.3.1 as the local line.

## 6. 0.3.2 — field findings & fixes (2026-09-17)

**Findings** (running 0.3.1 on a real machine):

- `pmset -g powermode` (“Currently in use”) reports the **active** domain:
  on AC it shows the AC value, on battery the battery value. A set via `-c`
  (v0.3.1 behavior) is **invisible while on battery** — machine cool on
  battery, guard requests high, set lands in the AC domain, read-back reports
  reduced → `VERIFY MISMATCH: requested High, system reports Reduced` + the
  warning banner, for the whole battery window (13:30–14:38 local, 2026-09-17;
  user had unplugged at 13:30). Self-resolved on re-plug. **Root cause: the
  guard was domain-blind.**
- pmset set→read has an apply lag (milliseconds): fast set + immediate
  read-back races (field blips during bursty 88↔72 °C load tests).
- **Battery safety floor (user rule):** on battery the guard must never
  restore high — the reduced cap is the only protection there (no user
  controllable fans) and battery comfort matters.

**0.3.2 changes**:

- sets target the domain the machine is **drawing from** (`-b` on battery,
  `-c` on AC; source tracked in-process by an **IOKit notification monitor**
  — `PowerSourceMonitor`: one initial query, then change notifications;
  no polling, no pmset for the source).
- battery rule in the decision: cool + reduced + on battery → **do nothing**
  (high returns only after AC + cool); hot on battery → reduced (the safe
  direction, unchanged). External-mode-change logs and the menu label now
  show the power source; a battery glyph marks battery state in the menu.
- warning lifecycle: a mismatch warning **clears as soon as the system
  settles on the requested mode** (2 s refresh path) — no more hour-long
  banners; plus one read-back retry ~0.5 s after each set to absorb the
  apply-lag race; and a **power-source change invalidates any stale warning**
  (requested High on AC, then unplug → the warning no longer applies).
- tests: domain targeting, battery no-restore, warning lifecycle (both
  clearing paths), power-source parsing; `PowerModeControllerState` gained
  `powerSource`.

**Not changed:** trigger thresholds, hysteresis, 100 ms tick, fan-side
behavior; 88↔72 flapping on bursty workloads remains (backlog: trigger
input); weak-AC detection added to the backlog (workaround: guard off +
manual reduced, documented in the README).
