# ThermalForge Idle CPU: Method and Evidence

## Summary in plain language

ThermalForge uses roughly **4% of one CPU core** while it is just sitting in the menu bar
with nothing open. We wanted to know exactly where that goes, and whether we could lower it
without making the app worse. We measured it rather than guessing.

Where the ~4% goes:

- **About two-thirds is reading the temperature sensors.** The app checks the Mac's
  internal temperatures ten times a second, so it can catch a brief heat spike that a slower
  check would miss. For comparison, a tool like TG Pro checks about once every two seconds by
  default.
  Checking this often, and double-checking that every reading is valid before it acts on it,
  is the single biggest cost, and it is the whole reason the app exists.
- **The rest** is drawing the menu bar display, writing its logs, noting which programs are
  running when a heat spike happens, and talking to its background helper. Each of these is
  small. We have put an upper limit on them together (see Experiments 3 to 5) and are not
  pursuing them individually, because the possible saving is too small to matter.

Could we make the ~4% smaller? Only by giving something up:

- **Reading the sensors more cheaply** would mean either checking each reading less
  carefully, that is, removing the step that confirms every reading is valid before the app
  acts on it, or watching fewer sensors. Both weaken exactly what the app is built to do. We
  are not doing that.
- **Drawing the menu less often** could save a little, but only a little (at most about a
  quarter of the total, and realistically less), and it would take a large rewrite of the
  app's internals for that small gain. Not worth it.

Bottom line: the ~4% is mostly the honest cost of the app's core job, watching temperatures
closely and safely. We are leaving it as is. The rest of this document is the detailed
method and evidence behind that conclusion, experiment by experiment.

---

This document records how we measure where ThermalForge's idle CPU actually goes,
in enough detail that a stranger can reproduce each experiment and get a comparable
number on their own machine. It is method and evidence, not opinion.

**Framing: we are measuring to know, not to change.** Each experiment isolates one
suspected cost and puts a number on it. If an experiment shows a cost is inherent to
how the app is designed to work (fast polling, per-process spike logging, a safety
read), then that is the finding, and we document *why* it is inherent. We do not
change the design to chase a number that buys nothing for the product.

All numbers here are from our own runs on our own machine: a Mac Studio (Apple Silicon),
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

Owner-run, privileged, per-process CPU ms/s and User%:

```
sudo powermetrics --samplers tasks --show-process-energy -i 5000 -n 24 \
  | grep -iE "Name|ThermalForge"
```

Non-privileged cross-check, cumulative user/system CPU time delta over 120 s for a
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

## Experiment 1: Does the UI render account for idle CPU?  **RESOLVED**

**Question.** People assume a menu bar app's idle CPU is the SwiftUI view constantly
re-rendering behind a closed dropdown. Is that where ThermalForge's idle CPU goes?

**Approach: turn off UI publishing, measure, compare.** One variable, one number, no
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

// DIAGNOSTIC (branch diag/ui-publish-off): publish OFF, Task hop retained
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
callback or the main-actor hop. Gating higher up, in the monitor, before the callback
fires, would additionally remove that hop and **over-credit** the result, reporting a
saving no achievable render fix could deliver. Leaving the monitor, the 500 ms cadence,
the sensor sweep, and the `Task` hop byte-for-byte identical, and removing only the four
`@Published` writes and the `maxTemp` filter, makes this the **honest ceiling** of what
any render fix could buy.

**How the diagnostic app was built and isolated.** The diagnostic build was assembled
into a proper `.app` bundle in `/tmp` and given a **distinct bundle identifier**
(`com.thermalforge.diag`, set with `plutil -replace CFBundleIdentifier` after assembly,
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
  identifier means a stray registration would corrupt the **real** app's login item,
  the same class of problem a bundle-less `.build/release/ThermalForgeApp` run causes
  (no bundle identity, leaving a stale registration behind). A distinct identifier
  points any login-item action at the throwaway bundle instead.

The real app was quit for the duration; the daemon (which owns fan control via a
uid-keyed socket, independent of the app's bundle id) kept running, so **fan control
stayed live throughout**, confirming this measures UI cost only, not function.

**Protocol.** Standard, as above: 2-minute settle, dropdown closed and untouched,
120-second window, `powermetrics` (owner-run) and the `ps` delta running concurrently,
storm rate recorded.

**Known limitation, stated up front.** The menu bar label and the dropdown share the
same `@Published` object, so disabling the publish freezes **all** UI: the menu bar
number and everything in the dropdown stick at their last value. This therefore measures
the ceiling of a **total UI freeze**, which is the *maximum* a render fix could ever
recover, not the expected gain of a real fix that keeps the UI live. Fan control is
unaffected (it runs off a separate callback).

### Results

| Condition | Total CPU | User / System | Storm |
|---|---|---|---|
| **Baseline** (publish ON, shipped 0.2.3) | **3.8% of one core** | ~44% user / ~56% system | 0.74 spikes/min |
| **Publish OFF** (this experiment) | **2.70% of one core** | ~22% user / ~78% system | 0 spikes in window |

Both windows were low-storm (0.74/min vs 0). Per our own convention a CPU number is only
comparable alongside its storm rate; these two are close but not identical, so a fraction
of the drop could be the ~0.74/min of spike-dump logging that the baseline window carried
and the publish-off window did not. That fraction is small (a sub-1/min dump rate is a
handful of log writes over 120 s), and it lands in the same direction as, and is dwarfed
by, the ~1.1pp user-side signal. It does not change the conclusion, but it is why the
system-time comparison (flat, 2.13% to 2.11%) is the load-bearing result: system time is
storm-insensitive here, so it is the cleaner of the two numbers.

**One more comparability caveat: the two runs used different bundles.** The baseline was
the installed `/Applications` app; the publish-off run was the `/tmp` bundle with a distinct
identifier, which means a **fresh `UserDefaults` domain** with no saved profile (it boots
to Silent) and no persisted update-check state. We treat that difference as negligible for
an idle CPU measurement, and here is why: at idle the machine sits well below every
profile's fan-start threshold, so the monitor does the **same** sensor-read, logging, and
tick work regardless of which profile is selected. Profile choice changes what happens
under load, not at rest; and the once-daily update check rides the heartbeat and performs no
network I/O within a settled window unless it is actually due. The residual is smaller than
the storm difference above and far smaller than the ~1.1pp signal. For a *strict* comparison
the honest move is to re-measure the baseline on an equivalently built `/tmp` bundle so both
runs share a bundle identity and a fresh defaults domain; we judge that unnecessary to
support this experiment's conclusion, and note it here so the assumption is on the record
rather than hidden.

Cross-check, publish OFF: `ps` reported **2.70%** at **78% system**; `powermetrics`
reported **2.69%** (26.87 ms/s mean of 24 samples) at **78% system**. The two
independent tools **agree to the hundredth of a percentage point**.

Decomposed against baseline:

- **User time:** ~1.67% to **0.59%** of one core, a drop of ~1.1pp.
- **System time:** 2.13% to **2.11%** of one core, essentially **flat**.

### Conclusion

**The ceiling on any render or `@Observable` fix is ~1.1 percentage points of one core,
entirely user-side.** Turning off *every* UI update left system time unmoved
(2.13% to 2.11%); ~78% of idle CPU is UI-independent. Even the total-freeze ceiling only
takes the app from 3.8% to 2.7%, and a fix that keeps the UI live buys less than that.

The UI render is **not** where ThermalForge's idle CPU lives. That closes the render
question. The majority of idle CPU is system time (syscalls), which no render change
can touch. Experiments 2 to 5 isolate the candidate syscall sources.

*(The branch `diag/ui-publish-off` was deleted after this run. It is a dead branch;
nothing from it shipped.)*

---

## Experiment 2: How much is the SMC sensor read?  **RESOLVED**

**Question.** Experiment 1 showed the majority of idle CPU is system time (syscalls) that
the UI does not cause. The prime suspect is the temperature sweep: every 100 ms the app
reads the Mac's sensors through the System Management Controller (SMC). How much does that
sweep actually cost?

**What the read path does (read from the code first).** The app runs its own sensor reader
and polls every 100 ms (`ThermalMonitor.tick()` calls `FanControl.status()`). Each tick
reads **61 keys**: the fan count, 5 values per fan (2 fans here), and **50 thermal keys**
(`FanControl.thermalKeys`). Crucially, each key read is **two** kernel calls, not one
(`SMCConnection.readKey`): a `readKeyInfo` call that returns the key's data size, then a
`readBytes` call that reads the value using that size. The `readKeyInfo` half is a
**per-read validity guarantee**; it confirms the key exists and hands back the exact size
used to decode the bytes (4-byte `flt` vs 8-byte `ioft`). So the plan's earlier "~500
ioctls/s" estimate was low by roughly 2x: it is closer to ~1,000+ `IOConnectCallStructMethod`
calls per second, because every key is an info+read pair. These calls cross into the
AppleSMC kernel driver, that is, they are **system time**. Of the 50 thermal keys, only the
36 CPU/GPU keys (`TC`/`Tp`/`TG`/`Tg`) drive the safety and fan decisions; the other 14
(memory, SSD, ambient, proximity, battery, power) are consumed only by the 500 ms display
and 2 s logging.

**Approach: three modes, one build, selected at launch.** To isolate the read cost we
built a single diagnostic binary with three modes, chosen by a launch argument
(`--tf-smc-mode`), so the only thing that varies between runs is the read strategy:

- **live**, the shipping path, unchanged: 50 keys, info+read pair each.
- **cached**, take one real snapshot at startup, then return it every tick with **zero SMC
  reads**. Everything downstream (safety math, process capture, logging, UI publish, daemon
  heartbeat) runs identically on the cached data. `live − cached` = the sensor read cost.
- **floor**, read only the 36 safety keys, with the size **cached** so each is a single
  call, and drop the 14 non-safety keys entirely. Fans read exactly as in live. This is the
  two rejected optimizations applied together (see below); it is **not** a design-compliant
  configuration.

**The exact code change** (branch `diag/smc-read-cost`, deleted after the run). A new
single-call read in `SMCConnection`, used only by the floor path:

```swift
// Reads bytes using an already-known size, skipping the readKeyInfo probe.
// Not for production: it trusts the cached size instead of revalidating it.
public func readBytesOnly(_ key: String, size: UInt32) -> (success: Bool, bytes: [UInt8], size: UInt32) {
    var input = SMCParamStruct(); var output = SMCParamStruct()
    input.key = fourCharCode(key)
    input.keyInfo.dataSize = size
    input.data8 = SMCCommand.readBytes.rawValue
    guard callSMC(&input, &output) == kIOReturnSuccess else { return (false, [], 0) }
    let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(size))) }
    return (true, bytes, size)
}
```

and `FanControl.status()` dispatching by mode:

```swift
public static let diagMode: SMCDiagMode = { /* parse --tf-smc-mode, default .live */ }()
private var cachedStatus: ThermalStatus?          // cached mode
private var cachedSizes: [String: UInt32] = [:]   // floor mode

public func status() throws -> ThermalStatus {
    switch Self.diagMode {
    case .live:   return try liveStatus()                 // shipping body, unchanged
    case .cached: if let c = cachedStatus { return c }
                  let s = try liveStatus(); cachedStatus = s; return s
    case .floor:  return try floorStatus()                // 36 safety keys, cached size, 1 call each
    }
}
```

**Isolation and honesty of the build.** Same as Experiment 1: assembled to a `/tmp` bundle
with the distinct identifier `com.thermalforge.diag` (separate `UserDefaults`, no login-item
reach), real app quit for the duration, installed daemon left running. The mode was passed
with `open /tmp/tf-diag/ThermalForge.app --args --tf-smc-mode <mode>`, and each run **logged
the mode it started in**, so the record proves the mode rather than assuming the argument
arrived. The diag defaults domain was cleared between runs so all three shared identical
fresh state.

**What freezes while each runs, stated plainly.**
- **cached:** temperatures are frozen at the startup snapshot, so the app is **blind to real
  heat** for the window (and spike detection cannot fire, so storm = 0). Idle-only, bounded,
  real app restored immediately after.
- **floor:** reads the safety keys live, so it **is** monitoring heat, safe to run.
- **live:** normal behavior.

### Results, three rounds (same protocol: `/tmp` bundle, 2-min settle, menu closed, 120 s)

| Mode | Tool | Total CPU | User | System | System share | Storm |
|---|---|---|---|---|---|---|
| **live** (50 keys, info+read) | `ps` | 4.26% core | 1.81% | 2.45% | 58% | 1.00/min |
| | `powermetrics` | 4.23% core (42.31 ms/s) | ~1.80% | ~2.43% | ~57% | n/a |
| **cached** (zero reads) | `ps` | 1.53% core | 1.18% | 0.36% | 23% | 0/min |
| | `powermetrics` | 1.52% core (15.16 ms/s) | ~1.16% | ~0.36% | ~24% | n/a |
| **floor** (36 keys, cached size) | `ps` | 3.08% core | 1.59% | 1.48% | 48% | 0.50/min |
| | `powermetrics` | 3.09% core (30.88 ms/s) | ~1.60% | ~1.49% | ~48% | n/a |

Both tools agree to 0.03pp or better on every round.

**Sweep cost = live − cached:**
- `ps`: 4.26% − 1.53% = **2.73pp**  (system 2.45 to 0.36 = 2.09pp; user 1.81 to 1.18 = 0.63pp)
- `powermetrics`: 4.23% − 1.52% = **2.71pp**
- **The sensor sweep is ~2.7pp of one core, about 64% of the app's idle CPU**, and ~77% of
  it is system time. This is the system-time mass Experiment 1 could not attribute.

**Comparability notes.**
- **Storm differed across the three rounds** (1.0 / 0 / 0.5 per min). Per our convention we
  record it. The effect is negligible here: at ~1/min a spike dumps a handful of log lines,
  tens of syscalls over the window, versus tens of thousands of sensor reads. It does not
  move the deltas.
- **Experiment 1's baseline (3.8%) and Experiment 2's Round 1 (4.26%) are different runs.**
  Different bundles (installed `/Applications` vs `/tmp`), different sessions, different storm
  rates (0.74 vs 1.00/min). They are the same app doing the same work in the same ballpark,
  not the same measurement. Do not subtract one from the other.

### Conclusion

The sensor sweep costs ~2.7pp of one core, ~64% of the app's idle CPU. ThermalForge keeps
two guarantees deliberately: every read validated, and every sensor covered. With both held,
the design-compliant minimum is the live sweep itself, so the entire 2.7pp is inherent. The
floor run shows only what abandoning both guarantees would have bought, at most ~1.18pp, and
only by dropping per-read validation on the safety keys and dropping the non-safety sensors
outright. We change nothing.

*(Branch `diag/smc-read-cost` was deleted after this run. Dead branch; nothing shipped.)*

---

## What we rejected, and what it would have cost

Plainly, for each change we considered and turned down, what it would gain and what it would
cost.

**UI render fix** (for example an `@Observable` rewrite, or publishing only while the panel
is open)
- **Gains:** up to **~1.1pp** of one core.
- **Costs:** a rewrite of the app's state layer. And that ~1.1pp is the ceiling measured with
  the UI **fully frozen** (Experiment 1); a real fix that keeps the display live buys less.
- **Verdict:** not worth a large rewrite for a fraction of a percent.

**Caching sensor sizes plus reducing sensor coverage**
- **Gains:** up to **~1.2pp** of one core, and that is a **ceiling, not the likely gain**.
  The floor run measured the two changes together, and it **dropped the 14 non-safety sensors
  entirely** rather than reading them at a slower cadence. A real change that merely read
  them less often would save less than dropping them. We also never measured size-caching on
  its own, so we cannot say how the ~1.2pp splits between the two changes.
- **Costs:** caching sizes removes the **per-read validation guarantee** (it trusts a
  remembered size instead of reconfirming it every read, a certainty downgraded to a
  detect-and-reprobe heuristic, while we still do not know why sensors occasionally drop
  out); reducing coverage removes **full-resolution logging**, which is part of the product
  (logging for science).
- **Verdict:** both rejected. These are the guarantees, not overhead.

**Batch SMC read** (one call returning several keys): **not pursued.** It would only help if
it preserved per-read validation, which is unproven, and idle CPU is marginal. Same category
as the size-caching compromise.

---

## Experiments 3, 4, 5: bounded, not run

These three remaining syscall sources were **not** measured individually, but Experiment 2's
**cached** run puts a ceiling on all of them combined: with the sensor reads removed, the
app's remaining **system time was ~0.36pp of one core** (Round 2). Log writes, the sysctl
process capture, and the daemon socket polls all live inside that ~0.4pp.

**Important caveat:** the cached run had **zero spike logging** (frozen temperatures never
trigger a spike dump), so the **log-write share is understated** there; a real spike storm
writes more.

We are not running these individually. The whole group is bounded at ~0.4pp, too small to
justify the work, and any reduction would run into the same kept guarantees as Experiment 2.
The method for each is recorded here in case that ever changes:

- **Experiment 3, log writing.** The logger opens, seeks, writes, and closes the file per
  line, bursty during a spike storm.
- **Experiment 4, sysctl process capture.** `KERN_PROC_ALL` every 2 s, which walks the whole
  process table.
- **Experiment 5, daemon socket round trips.** Heartbeat, version, and state, three socket
  connections every 5 s.

---

## Where the investigation stands

Idle CPU is ~4% of one core. Experiment 1 ruled out UI render as the driver (~1.1pp ceiling,
all user-side). Experiment 2 found the sensor sweep is the majority (~2.7pp, ~64%, mostly
system time) and, because full validation and full coverage are kept deliberately, that cost
is inherent to the design. Experiments 3 to 5 (log writes, process capture, daemon sockets)
are together bounded at ~0.4pp and left unrun. **The practical outcome: nothing to change.**
The idle CPU is the honest cost of the app's core job, and every reduction on the table
trades away a guarantee we keep on purpose.

All measurements are our own, on our own machine; nothing in this investigation is drawn from
external reports.
