# ThermalForge — Idle CPU: Method and Evidence

This document records how we measure where ThermalForge's idle CPU actually goes,
in enough detail that a stranger can reproduce each experiment and get a comparable
number on their own machine. It is method and evidence, not opinion.

**Framing: we are measuring to know, not to change.** Each experiment isolates one
suspected cost and puts a number on it. If an experiment shows a cost is inherent to
how the app is designed to work — fast polling, per-process spike logging, a safety
read — then that is the finding, and we document *why* it is inherent. We do not
change the design to chase a number that buys nothing for the product.

All numbers here are from our own runs on our own machine — an Apple Silicon MacBook,
macOS (Darwin 25.0), shipped build **0.2.3**, menu bar app idle with the dropdown
closed. Absolute percentages are machine-specific; the **method** is what transfers.
Reproduce it to get *your* number.

## How we measure (conventions shared by every experiment)

- **Per-PID, never system-wide.** We measure the `ThermalForgeApp` PID (and the
  `thermalforge` daemon PID) directly, so other apps can't contaminate the number.
- **Two independent tools, and they must agree.** A privileged, owner-run
  `powermetrics` for per-process CPU ms/s and User%, cross-checked against a
  non-privileged `ps` utime/stime delta over the same window. If they disagree, the
  measurement is not trusted.
- **Same protocol every run, so windows are comparable:** fresh quit and relaunch,
  the dropdown stays **closed and untouched**, settle **2 minutes**, then a **120-second**
  window with both tools running concurrently.
- **Record the spike-storm rate during the window.** ThermalForge logs a
  per-process dump on each thermal spike; that logging's cost co-varies with how much
  the temperature is oscillating. A CPU number without its concurrent storm rate is not
  comparable to another. We count `Instant spike:` log lines inside the window.
- **Diagnostics are throwaway.** Each experiment that needs a code change uses a
  short-lived branch that is deleted after the run. No instrumentation ships.

### The two measurement commands

Owner-run, privileged — per-process CPU ms/s and User%:

```
sudo powermetrics --samplers tasks --show-process-energy -i 5000 -n 24 \
  | grep -iE "Name|ThermalForge"
```

Non-privileged cross-check — cumulative user/system CPU time delta over 120 s for a
given PID, plus the storm rate from the log:

```
LOG=~/Library/Logs/ThermalForge/thermalforge-$(date +%F).log
PID=<ThermalForgeApp pid>
sp0=$(grep -c "Instant spike:" "$LOG"); t0=$(ps -o utime=,stime= -p $PID)
sleep 120
t1=$(ps -o utime=,stime= -p $PID); sp1=$(grep -c "Instant spike:" "$LOG")
# Convert MM:SS.cc utime/stime to seconds, take the delta, divide by 120s
# for "% of one core"; system share = Δstime / Δtotal; storm = (sp1-sp0)/2 per min.
```

The two must land on the same total and the same user/system split.

---

## Experiment 1 — Does the UI render account for idle CPU?  **RESOLVED**

**Question.** People assume a menu bar app's idle CPU is the SwiftUI view constantly
re-rendering behind a closed dropdown. Is that where ThermalForge's idle CPU goes?

**Approach — turn off UI publishing, measure, compare.** One variable, one number, no
attribution guesswork. ThermalForge's entire UI is driven from a single point: a
`ThermalMonitor` callback (`AppState.onUpdate`) fires every 500 ms and writes four
`@Published` properties that the menu bar label and the dropdown both observe. Disabling
those writes eliminates every SwiftUI redraw at once.

**The exact code change.** In `Sources/ThermalForgeApp/AppState.swift`, the callback is
turned into a no-op *before* the `@Published` writes, while the `Task { @MainActor }`
hop is deliberately **kept**:

```swift
// SHIPPED
monitor.onUpdate = { [weak self] status, profile, state in
    Task { @MainActor [weak self] in
        self?.latestStatus = status
        self?.activeProfile = profile
        self?.monitorState = state
        let displayPrefixes = ["TC", "Tp", "TG", "Tg"]
        self?.maxTemp = status.temperatures
            .filter { key, _ in displayPrefixes.contains(where: { key.hasPrefix($0) }) }
            .values.max()
    }
}

// DIAGNOSTIC (branch diag/ui-publish-off) — publish OFF, Task hop retained
monitor.onUpdate = { [weak self] status, profile, state in
    _ = (status, profile, state)
    Task { @MainActor [weak self] in
        _ = self
        // all four @Published writes + the maxTemp filter removed
    }
}
```

**Why keep the empty `Task` hop.** A real render fix (for example an `@Observable`
migration, or only publishing while the panel is open) would still *receive* the
update on the main actor and then decide to do less UI work. It would not delete the
callback or the main-actor hop. Gating higher up — in the monitor, before the callback
fires — would additionally remove that hop and **over-credit** the result, reporting a
saving no achievable render fix could deliver. Leaving the monitor, the 500 ms cadence,
the sensor sweep, and the `Task` hop byte-for-byte identical, and removing only the four
`@Published` writes and the `maxTemp` filter, makes this the **honest ceiling** of what
any render fix could buy.

**How the diagnostic app was built and isolated.** The diagnostic build was assembled
into a proper `.app` bundle in `/tmp` and given a **distinct bundle identifier**
(`com.thermalforge.diag`, set with `plutil -replace CFBundleIdentifier` after assembly —
so the only source change stays the one-line callback edit):

```
swift build -c release --disable-sandbox
.build/release/thermalforge build-app \
  --binary .build/release/ThermalForgeApp --icon ThermalForge.icns \
  --dest /tmp/tf-diag/ThermalForge.app
plutil -replace CFBundleIdentifier -string com.thermalforge.diag \
  /tmp/tf-diag/ThermalForge.app/Contents/Info.plist
open /tmp/tf-diag/ThermalForge.app
```

This matters, and it is not optional:

- `UserDefaults.standard` is keyed by the bundle identifier
  (`~/Library/Preferences/<id>.plist`). A shared identifier would let the diagnostic
  app read and overwrite the real app's saved profile, temperature unit, and
  update-check state. A distinct identifier gives it a separate preferences file it
  cannot cross.
- `SMAppService.mainApp` (the login item) targets the running bundle. A shared
  identifier means a stray registration would corrupt the **real** app's login item —
  the same class of problem a bundle-less `.build/release/ThermalForgeApp` run causes
  (no bundle identity, leaving a stale registration behind). A distinct identifier
  points any login-item action at the throwaway bundle instead.

The real app was quit for the duration; the daemon (which owns fan control via a
uid-keyed socket, independent of the app's bundle id) kept running, so **fan control
stayed live throughout** — confirming this measures UI cost only, not function.

**Protocol.** Standard, as above: 2-minute settle, dropdown closed and untouched,
120-second window, `powermetrics` (owner-run) and the `ps` delta running concurrently,
storm rate recorded.

**Known limitation, stated up front.** The menu bar label and the dropdown share the
same `@Published` object, so disabling the publish freezes **all** UI — the menu bar
number and everything in the dropdown stick at their last value. This therefore measures
the ceiling of a **total UI freeze**, which is the *maximum* a render fix could ever
recover — not the expected gain of a real fix that keeps the UI live. Fan control is
unaffected (it runs off a separate callback).

### Results

| Condition | Total CPU | User / System | Storm |
|---|---|---|---|
| **Baseline** (publish ON, shipped 0.2.3) | **3.8% of one core** | ~44% user / ~56% system | low |
| **Publish OFF** (this experiment) | **2.70% of one core** | ~22% user / ~78% system | 0 in window |

Cross-check, publish OFF: `ps` reported **2.70%** at **78% system**; `powermetrics`
reported **2.69%** (26.87 ms/s mean of 24 samples) at **78% system**. The two
independent tools **agree to the hundredth of a percentage point**.

Decomposed against baseline:

- **User time:** ~1.67% → **0.59%** of one core — a drop of ~1.1pp.
- **System time:** 2.13% → **2.11%** of one core — **flat**.

### Conclusion

**The ceiling on any render or `@Observable` fix is ~1.1 percentage points of one core,
entirely user-side.** Turning off *every* UI update left system time unmoved
(2.13% → 2.11%); ~78% of idle CPU is UI-independent. Even the total-freeze ceiling only
takes the app from 3.8% to 2.7%, and a fix that keeps the UI live buys less than that.

The UI render is **not** where ThermalForge's idle CPU lives. That closes the render
question. The majority of idle CPU is system time — syscalls — which no render change
can touch. Experiments 2–5 isolate the candidate syscall sources.

*(The branch `diag/ui-publish-off` was deleted after this run. It is a dead branch;
nothing from it shipped.)*

---

## Experiment 2 — How much is the SMC sensor read?

Tests the ~50 SMC keys read every 100 ms through IOKit — roughly 500 ioctls per second.

## Experiment 3 — How much is log writing?

Tests the logger opening, seeking, writing, and closing the file per line, bursty during
a spike storm.

## Experiment 4 — How much is the sysctl process capture?

Tests the `KERN_PROC_ALL` sysctl every 2 seconds, which walks the entire process table.

## Experiment 5 — How much are the daemon socket round trips?

Tests the heartbeat, version, and state polls — three socket connections every 5 seconds.

---

*Experiments 2–5 are unrun. Each will get its own throwaway branch, deleted after, and a
full write-up here only once we have the number. All measurements are our own, on our own
machine; nothing in this investigation is drawn from external reports.*
