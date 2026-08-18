//
//  AppState.swift
//  ThermalForge
//
//  Observable bridge between ThermalMonitor and SwiftUI.
//

import ServiceManagement
import SwiftUI
@preconcurrency import ThermalForgeCore

@MainActor
final class AppState: ObservableObject {
    @Published var latestStatus: ThermalStatus?
    @Published var activeProfile: FanProfile = .silent
    @Published var monitorState: MonitorState = .idle
    @Published var maxTemp: Float?
    @Published var useFahrenheit: Bool = UserDefaults.standard.bool(forKey: "useFahrenheit") {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: "useFahrenheit") }
    }
    @Published var launchAtLogin: Bool = false {
        didSet { updateLoginItem() }
    }
    /// The running daemon's version when it differs from this app's build, else
    /// nil. Non-nil drives the "update needed" banner and menu bar badge — the
    /// long-lived daemon keeps running the old binary after a `brew upgrade`
    /// until `sudo thermalforge install` re-syncs it.
    @Published var daemonVersionMismatch: String?
    /// A hold set from the CLI (`sudo thermalforge max`) that the app is
    /// reflecting rather than fighting. Non-nil suspends the app's automatic
    /// profile control and drives the "held from Terminal" banner; the user
    /// takes back over by picking a profile or pressing Default.
    @Published var externalHold: DaemonHoldState?
    /// True when the daemon has stopped answering (two consecutive missed
    /// heartbeats). Drives the "fan control unavailable" banner + Restart button:
    /// without the daemon the app can't control fans at all, so this must be
    /// visible, not just logged. Cleared the moment a heartbeat succeeds.
    @Published var daemonUnreachable: Bool = false

    private var monitor: ThermalMonitor?
    private let executor = PrivilegedExecutor()
    private var heartbeatTimer: DispatchSourceTimer?
    /// Consecutive failed heartbeats, for debouncing `daemonUnreachable`.
    private var heartbeatFailures = 0

    /// Runs the 5s heartbeat/version/state polls OFF the main thread so a slow
    /// or hung daemon can never stall the UI run loop (the v0.1.7 freeze).
    private let heartbeatQueue = DispatchQueue(label: "com.thermalforge.heartbeat", qos: .utility)
    /// Off-main, serial, coalescing pump for all daemon-bound fan writes (launch
    /// adopt + monitor ramp commands). It owns its own queue, so this @MainActor
    /// class never runs socket I/O on the main actor — off-main by construction,
    /// not by relying on lax isolation. The injected executor closure runs on the
    /// pump's queue; a CLI-hold rejection is reflected back onto externalHold on the
    /// main actor.
    private lazy var commandPump: FanCommandPump = {
        let executor = self.executor   // capture the Sendable executor value (off-main use)
        return FanCommandPump { [weak self] command in
            do {
                try executor.execute(command)
                return true
            } catch {
                // Failure is NEVER silent. If a CLI hold owns the fans, this is
                // expected arbitration — reflect it on the main actor so the monitor
                // stops trying and the banner appears immediately (don't wait up to
                // 5s for the poll). Otherwise it's a real failure — log it.
                if let state = try? DaemonClient().readState(), state.isCLIHold {
                    TFLogger.shared.info("Fan command yielded to CLI hold: \(command)")
                    Task { @MainActor in self?.externalHold = state }
                } else {
                    TFLogger.shared.error("Fan command failed: \(command) — \(error)")
                }
                return false
            }
        }
    }()

    init() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)

        adoptDaemonStateOnLaunch()

        // Clean expired logs
        ThermalLogger.cleanExpired()

        startMonitoring()
        // startHeartbeat() is intentionally NOT called here — it is launched from
        // adoptDaemonStateOnLaunch()'s @MainActor completion (the ordering gate),
        // so the first heartbeat poll can never land before adopt has applied the
        // launch state. The original synchronous adopt gave this ordering for free;
        // the async version must restore it explicitly.
    }

    /// Sync to whatever the daemon is actually holding at launch instead of
    /// blindly resetting (which destroyed a deliberate CLI hold and the daemon's
    /// record of it). A CLI hold is reflected and left alone; a stale supervised
    /// hold left by a crashed prior app instance is cleared here — that's the
    /// crash recovery the old reset provided, without the collateral damage.
    private func adoptDaemonStateOnLaunch() {
        let executor = self.executor
        // Read the daemon's launch state OFF the main thread so an unresponsive
        // daemon can't stall app launch — the socket read is bounded by the sendRaw
        // timeout. runAtLaunch puts this on the pump's serial queue AHEAD of any
        // ramp write, so a stale-hold reset here can never be reordered behind a
        // monitor command. During the brief pre-adopt window the monitor may still
        // issue a command; shipped arbitration rejects an app write over a CLI hold
        // and the pump latches it, so no fan state is corrupted.
        commandPump.runAtLaunch { [weak self] in
            let state = try? DaemonClient().readState()

            // Same four-way decision as before, just resolved off-main; any reset
            // runs here and only the resulting externalHold is applied on main.
            let adopted: DaemonHoldState?
            if let state, state.isCLIHold {
                // Deliberate CLI hold — reflect it, don't touch it.
                adopted = state
                TFLogger.shared.info("App launched — reflecting CLI hold: \(state.command ?? "?")")
            } else if let state, !state.isEmpty {
                // Leftover supervised hold from a crashed prior instance — this is
                // the live app now, so take over by clearing it (the crash
                // recovery the old blind reset provided).
                adopted = nil
                try? executor.execute(.resetAuto)
                TFLogger.shared.info("App launched — cleared stale app hold")
            } else if state != nil {
                adopted = nil
                TFLogger.shared.info("App launched — no active hold")
            } else {
                // State unreadable — a pre-0.1.7 daemon with no `state` verb
                // (upgrade window) or unreachable. DELIBERATE fallback to the old
                // conservative reset: without arbitration we can't tell a CLI hold
                // from a crashed prior instance's stale hold, and leaving fans
                // possibly stuck is worse than clearing a possible CLI hold.
                // Bounded to the pre-0.1.7 daemon window, where the version-
                // mismatch banner already tells the user to re-sync.
                adopted = nil
                try? executor.execute(.resetAuto)
                TFLogger.shared.info("App launched — daemon state unreadable; reset to auto (degraded)")
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.externalHold = adopted
                // Ordering gate: only now that adopt has applied the launch state
                // do we start the heartbeat. This makes adopt's externalHold write
                // strictly precede the first poll's write, so a late adopt (e.g. the
                // timeout path, ~4s) can't clobber a fresher heartbeat value. It
                // also means an unbounded connect() inside adopt merely delays the
                // first heartbeat (all off the main thread) — it never stalls launch.
                self.startHeartbeat()
            }
        }
    }

    deinit {
        heartbeatTimer?.cancel()
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        let client = DaemonClient()
        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            // Runs OFF the main thread. Each socket round-trip is bounded by the
            // request timeout, so a hung daemon can no longer stall the UI.

            // Heartbeat is NOT advisory: it refreshes the supervised hold's
            // liveness and the daemon watchdog reverts after 15s of silence. One
            // immediate retry absorbs a transient blip without waiting a full 5s
            // for the next tick.
            let firstBeat = (try? client.request(DaemonRequest(verb: .heartbeat)))?.ok == true
            let hbOK = firstBeat || ((try? client.request(DaemonRequest(verb: .heartbeat)))?.ok == true)

            // Advisory: version + state. On failure/timeout DON'T assert — leave
            // the last known value untouched rather than clearing the banner on a
            // transient blip. Only a definitive read updates published state. Both
            // the `version` reply and an `unsupportedVersion` reply carry the
            // daemon's build; a reply without one is treated as an older build.
            let didReadVersion: Bool
            let versionValue: String?
            do {
                let response = try client.request(DaemonRequest(verb: .version))
                let daemonVersion = response.version ?? "an older build"
                versionValue = (daemonVersion == ThermalForgeVersion.current) ? nil : daemonVersion
                didReadVersion = true
            } catch DaemonError.incompatibleDaemon {
                // Legacy (pre-Phase-2) daemon in the upgrade window → show the
                // update-needed banner rather than leaving it stale.
                versionValue = "an older build"
                didReadVersion = true
            } catch {
                versionValue = nil
                didReadVersion = false
            }

            // Poll the daemon's hold so a CLI hold set out-of-band shows up in the
            // menu bar and suspends our monitor. Unreadable → leave externalHold
            // as-is (don't clear a reflected CLI hold on a transient failure).
            let didReadState: Bool
            let holdValue: DaemonHoldState?
            if let hold = try? client.readState() {
                holdValue = hold.isCLIHold ? hold : nil
                didReadState = true
            } else {
                holdValue = nil
                didReadState = false
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                if didReadVersion { self.daemonVersionMismatch = versionValue }
                if didReadState { self.externalHold = holdValue }
                // Daemon reachability — debounced so a single blip doesn't flash the
                // "fan control unavailable" banner. Two consecutive missed heartbeats
                // (~10s) is a real outage; any success clears it immediately.
                if hbOK {
                    self.heartbeatFailures = 0
                    self.daemonUnreachable = false
                } else {
                    self.heartbeatFailures += 1
                    if self.heartbeatFailures >= 2 { self.daemonUnreachable = true }
                }
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard let fc = try? FanControl() else { return }

        let monitor = ThermalMonitor(fanControl: fc, profile: activeProfile)
        monitor.onUpdate = { [weak self] status, profile, state in
            Task { @MainActor [weak self] in
                self?.latestStatus = status
                self?.activeProfile = profile
                self?.monitorState = state
                // Max of only the displayed sensors
                // Peak across all CPU and GPU sensors for menu bar display
                let displayPrefixes = ["TC", "Tp", "TG", "Tg"]
                self?.maxTemp = status.temperatures
                    .filter { key, _ in displayPrefixes.contains(where: { key.hasPrefix($0) }) }
                    .values.max()
            }
        }
        monitor.onFanCommand = { [weak self] command in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Don't fight a CLI hold — the user set it deliberately. Decide on
                // the main actor where externalHold lives; the monitor resumes
                // control when they pick a profile or press Default.
                guard self.externalHold == nil else { return }
                // Hand off to the coalescing pump; the blocking socket write happens
                // OFF the main thread. During a ramp these fire up to ~10x/sec;
                // previously each ran a blocking round-trip on the main actor and
                // starved the run loop (v0.1.7).
                self.commandPump.submit(command)
            }
        }
        monitor.start()
        self.monitor = monitor
    }

    // MARK: - Actions

    /// Explicit user takeover of any reflected CLI hold. Returns whether one was
    /// active, so the caller can clear the daemon's unsupervised hold (send a
    /// command) rather than leave it orphaned.
    @discardableResult
    private func seizeControl() -> Bool {
        let had = externalHold != nil
        externalHold = nil
        return had
    }

    func setSmart() {
        let took = seizeControl()
        activeProfile = .smart
        monitor?.switchProfile(.smart)
        // Taking over a CLI hold: clear it so the unsupervised hold isn't
        // orphaned; the Smart tick then establishes supervised control. Off-main
        // one-shot on the pump (never coalesced/reordered).
        if took { commandPump.submit(.resetAuto) }
        TFLogger.shared.profile("Smart activated")
    }

    func resetAuto() {
        seizeControl()
        // resetAuto clears any hold (CLI or app) → daemon .none. This is the
        // no-CLI-knowledge way out of a pinned CLI hold: the Default button, and
        // the escape for someone with loud fans. Unlike setSmart/selectProfile
        // (where the monitor keeps working and retries every tick), Default takes
        // the monitor hands-off — so it must NOT claim success it didn't get.
        // Send the reset off-main and reflect Silent ONLY once the daemon confirms;
        // on failure, leave the current profile active (so the monitor keeps trying)
        // and log it, rather than a false "Silent, handled" over a dead daemon.
        commandPump.submit(.resetAuto) { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                guard ok else {
                    TFLogger.shared.error("Reset to Default failed — daemon unreachable; fans NOT reset")
                    return
                }
                self.activeProfile = .silent
                self.monitor?.switchProfile(.silent)
                TFLogger.shared.profile("Reset to Default (Silent (Apple Default))")
            }
        }
    }

    func selectProfile(_ profile: FanProfile) {
        let took = seizeControl()
        activeProfile = profile
        monitor?.switchProfile(profile)
        TFLogger.shared.profile("Selected: \(profile.name)")

        // Reset to auto when switching to a hands-off profile, OR when taking over
        // a CLI hold (so its unsupervised hold isn't orphaned). Otherwise active
        // profiles let tick() ramp from the current temperature. Off-main one-shot
        // on the pump (never coalesced/reordered).
        if profile.curve.handsOff || profile.id == "smart" || profile.id == "silent" || took {
            commandPump.submit(.resetAuto)
        }
    }

    // MARK: - Daemon recovery

    /// Force the root daemon to restart via launchd, from the "Restart daemon"
    /// button on the unreachable banner. Runs OFF the main thread (it blocks on the
    /// macOS auth dialog). Uses `launchctl kickstart -k` — the standard "restart
    /// this service" — via an Authorization prompt: macOS shows the password dialog
    /// and handles the credential; the app never sees it. On success the next
    /// heartbeat clears `daemonUnreachable`.
    func restartDaemon() {
        let label = ThermalForgeDaemon.label
        DispatchQueue.global(qos: .userInitiated).async {
            // Escaped for AppleScript's `do shell script`; the label is a fixed
            // constant (no user input), so there's nothing untrusted to inject.
            let script = "do shell script \"/bin/launchctl kickstart -k system/\(label)\" with administrator privileges"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    TFLogger.shared.info("Restart daemon: launchctl kickstart requested")
                } else {
                    // Non-zero includes the user cancelling the auth prompt (-128).
                    TFLogger.shared.error("Restart daemon failed (osascript exit \(p.terminationStatus))")
                }
            } catch {
                TFLogger.shared.error("Restart daemon failed to launch: \(error)")
            }
        }
    }

    // MARK: - Launch at Login

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            TFLogger.shared.error("Launch at login toggle failed: \(error)")
            launchAtLogin = !launchAtLogin // revert toggle
        }
    }
}
