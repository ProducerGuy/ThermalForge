# M4 fan handoff and daemon transport repair

Hardware acceptance used a locally installed **0.2.3.2** repair build. That identifier is not an upstream release; this change leaves the upstream application version unchanged.

The repair was developed against upstream v0.2.3 (`3fbaa527aee05a5a0ed2606f00b50254df9d614f`) and ported onto this fork's `8a344f6` baseline. The intervening commits only changed the idle-CPU investigation document; those changes are preserved. Core source and regression tests are identical to the locally tested repair.

## Failure

On one M4 Max MacBook Pro, initial fan acquisition from a fully stopped state took longer than the daemon client's two-second timeout. Subsequent state/heartbeat requests also waited behind the hardware lock. The framing layer reported timeout, read failure and EOF as the same `closed` error, making this look like a lost daemon connection.

The connection server's five-second request deadline also included hardware processing and the response write. A valid but slow hardware command could therefore lose its reply. A client disconnect could expose the daemon to SIGPIPE.

Separately, the original per-fan ten-second acquisition limit was insufficient for some cold starts. A first repair build retaining that limit failed after 10.714 seconds even though all 207 concurrent liveness queries succeeded. The final build uses a shared twenty-second acquisition budget; one successful hardware run took over thirteen seconds.

## Changes

| Area | Repair |
| --- | --- |
| Manual acquisition | One monotonic twenty-second budget across the requested fans, rather than ten seconds per fan. |
| Already-manual fans | Read the actual modes on each call and skip unnecessary `Ftst`, mode writes and sleeps. A system handback or wake is not hidden by cached ownership. |
| Client timeout | Thirty seconds for `max`, `set`, `setfan` and `auto`; two seconds retained for queries. These are socket/connect timeouts, not a universal end-to-end latency guarantee under contention. |
| Lock scope | `state`, `heartbeat` and `version` use their existing state synchronization without waiting for the SMC lock. Hardware reads/writes, including `status`, still use that lock. |
| Connection deadlines | Keep the one-second header deadline and separate five-second body/read and response/write deadlines. Do not count synchronous hardware execution against the frame I/O deadline. |
| Broken connections | Set `SO_NOSIGPIPE` on client and accepted sockets; retry interrupted frame I/O; distinguish timeout, EOF and other read errors. |

The connection cap, frame-size cap, command-rate limit and ownership rules remain in place. The profile definitions, temperature monitor and safety invariants are unchanged, including the 95°C safety override. This repair neither changes model/runtime settings nor imposes a new power limit. It does not suppress the high-temperature warning icon.

## Build and automated tests

From this fork's checkout, using a compatible Swift toolchain on macOS:

```sh
swift test --jobs 2
swift build -c release --jobs 2
```

Both commands passed in a fresh checkout of this fork after the repair was transferred. The release CLI reports `0.2.3.2`; this is local verification, not a claim that GitHub Actions ran.

The test suite contains 57 tests, including eight added in `LocalHandoffRepairTests.swift`. The added tests do not access real fan hardware. They cover:

- already-manual and partially manual fast paths;
- simulated twelve-second acquisition and re-reading modes after system handback;
- bounded acquisition failure and per-command timeout/lock policy;
- socket read timeout versus EOF;
- a slow reply surviving the frame deadline while liveness requests complete;
- a disconnected client followed by a successful request.

These tests do not replace hardware acceptance or prove wake behavior on every model.

## Hardware acceptance: 2026-09-21

Reported local hardware: Mac16,5, M4 Max (40-core GPU, 64 GB), macOS 27.0. The final repair was installed before these measurements. Inference was paused; no CPU/GPU stress workload was generated.

Each run started with both fans at 0 RPM under system control, requested maximum speed, queried `version`/`state`/`heartbeat` during acquisition, waited five seconds for physical spin-up, and repeated the same speed command three times. At the end the CLI hold was cleared and the menu bar application reopened with its saved Smart profile.

| Measurement | Run 1 | Run 2 |
| --- | --- | --- |
| Command completion, including test polling overhead | 8.378 s | 13.022 s |
| Concurrent liveness requests | 162, no errors | 252, no errors |
| Maximum liveness latency | 4.552 ms | 1.909 ms |
| Actual fan speeds after the additional five seconds | 5,792 / 5,803 RPM | 5,836 / 5,808 RPM |
| Requested speed for both fans | 5,777 RPM | 5,777 RPM |
| Subsequent same-speed command latency, including CLI startup | 10.777–11.646 ms | 14.095–18.929 ms |
| Final state | Smart restored; no CLI hold | Smart restored; no CLI hold |

The daemon did not restart during these runs. Application logs contained no new errors during the final-build acceptance window. Preferences and the existing launchd configuration were unchanged. A pre-existing local launchd SIGPIPE-ignore wrapper was retained during hardware acceptance; the socket regression test separately exercises the repair without depending on that wrapper. The wrapper and machine-specific installation/rollback scripts are not part of this repository change.

**Limits:** these are two cold-handoff runs on one machine, not long-duration, reboot or sleep/wake acceptance. Hardware acquisition still takes seconds. The repair does not guarantee a lower sustained GPU temperature, a permanent absence of communication errors, or identical behavior on other Apple Silicon generations.

## Review scope

The six implementation/test files in this change match the locally accepted repair. The application version and upstream README are unchanged. No install script, machine-specific configuration, temperature threshold, or profile curve is modified by this PR.

The hardware measurements above describe the earlier local repair build, not an additional test of a newly installed upstream build. Reboot, sleep/wake and long-duration loaded acceptance remain outside those measurements.

## Upstream PR validation: 2026-09-21

On the upstream review branch, `swift build -c release --jobs 2` passed, and `swift test --jobs 2 --skip ProfileTests.saveLoad` passed **56 tests in 9 suites**, including all eight handoff/transport regressions. The existing `ProfileTests.saveLoad` test was excluded because it writes to the real user's Application Support profiles directory; changing that unrelated test is outside this transport PR. The earlier complete 57-test run above remains historical acceptance of the locally installed repair.
