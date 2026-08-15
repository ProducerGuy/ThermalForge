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
    // Keep Apple-default behavior on first launch. Smart remains selectable
    // from the menu bar; the local diagnostic build used Smart explicitly.
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

    private var monitor: ThermalMonitor?
    private let executor = PrivilegedExecutor()
    private var heartbeatTimer: Timer?
    private var heartbeatInFlight = false
    /// Daemon commands are serialized and coalesced. A stalled daemon must not
    /// create one detached task per 100ms ramp tick; only the newest pending
    /// RPM target is useful once the socket becomes available again.
    private var pendingFanCommand: FanCommand?
    private var fanCommandInFlight = false

    init() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)

        adoptDaemonStateOnLaunch()

        // Clean expired logs
        ThermalLogger.cleanExpired()

        startMonitoring()
        startHeartbeat()
    }

    /// Sync to whatever the daemon is actually holding at launch instead of
    /// blindly resetting (which destroyed a deliberate CLI hold and the daemon's
    /// record of it). A CLI hold is reflected and left alone; a stale supervised
    /// hold left by a crashed prior app instance is cleared here — that's the
    /// crash recovery the old reset provided, without the collateral damage.
    private func adoptDaemonStateOnLaunch() {
        guard let state = try? DaemonClient().readState() else {
            // State unreadable — a pre-0.1.7 daemon with no `state` verb (upgrade
            // window) or unreachable. DELIBERATE fallback to the old conservative
            // reset: without arbitration we can't tell a CLI hold from a crashed
            // prior instance's stale hold, and leaving fans possibly stuck is
            // worse than clearing a possible CLI hold. Bounded to the pre-0.1.7
            // daemon window, where the version-mismatch banner already tells the
            // user to re-sync.
            externalHold = nil
            try? executor.execute(.resetAuto)
            TFLogger.shared.info("App launched — daemon state unreadable; reset to auto (degraded)")
            return
        }

        if state.isCLIHold {
            // Deliberate CLI hold — reflect it, don't touch it.
            externalHold = state
            TFLogger.shared.info("App launched — reflecting CLI hold: \(state.command ?? "?")")
        } else if !state.isEmpty {
            // Leftover supervised hold from a crashed prior instance — this is the
            // live app now, so take over by clearing it (the crash recovery the
            // old blind reset provided).
            externalHold = nil
            try? executor.execute(.resetAuto)
            TFLogger.shared.info("App launched — cleared stale app hold")
        } else {
            externalHold = nil
            TFLogger.shared.info("App launched — no active hold")
        }
    }

    deinit {
        heartbeatTimer?.invalidate()
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startHeartbeatRequest()
            }
        }
    }

    @MainActor
    private func startHeartbeatRequest() {
        guard !heartbeatInFlight else { return }
        heartbeatInFlight = true

        // Every daemon request has bounded socket I/O, but keep the whole
        // heartbeat off MainActor so a slow daemon can never pause SwiftUI.
        Task.detached { [weak self] in
            let client = DaemonClient()
            _ = try? client.send("heartbeat")

            // Piggyback a version check on the heartbeat. Detect the raw "error:"
            // reply from a daemon too old to know the `version` command, and
            // treat it as an older build rather than a version number.
            let mismatch: String?
            if let response = try? client.sendRaw("version") {
                let daemonVersion = response.hasPrefix("error:") ? "an older build" : response
                mismatch = daemonVersion == ThermalForgeVersion.current ? nil : daemonVersion
            } else {
                mismatch = nil  // can't reach it — don't assert a mismatch we can't prove
            }

            // Poll the daemon's hold so a CLI hold set out-of-band shows up in the
            // menu bar and suspends our monitor (nil if unreadable — don't guess).
            let hold = try? client.readState()

            await self?.completeHeartbeat(mismatch: mismatch, hold: hold)
        }
    }

    @MainActor
    private func completeHeartbeat(mismatch: String?, hold: DaemonHoldState?) {
        daemonVersionMismatch = mismatch
        externalHold = (hold?.isCLIHold == true) ? hold : nil
        heartbeatInFlight = false
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
                // Prefer aggregate TC* sensors when present. The Tp0* aliases
                // on M4/M5 can be placeholder values and must not drive the UI
                // temperature or Smart profile.
                let hasAggregateCPU = status.temperatures.keys.contains { $0.hasPrefix("TC") }
                let displayPrefixes = hasAggregateCPU ? ["TC", "TG", "Tg"] : ["Tp", "TG", "Tg"]
                self?.maxTemp = status.temperatures
                    .filter { key, _ in displayPrefixes.contains(where: { key.hasPrefix($0) }) }
                    .values.max()
            }
        }
        monitor.onFanCommand = { [weak self] command in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Don't fight a CLI hold — the user set it deliberately. The
                // monitor resumes control when they pick a profile or press
                // Default (which clears externalHold).
                guard self.externalHold == nil else { return }

                // DaemonClient.sendRaw performs a blocking Unix-socket read.
                // Never run it on MainActor: a slow SMC transaction must not
                // freeze the menu bar or make Bartender appear to intercept it.
                self.enqueueFanCommand(command)
            }
        }
        monitor.start()
        self.monitor = monitor
    }

    @MainActor
    private func latchExternalHold(_ state: DaemonHoldState) {
        externalHold = state
    }

    @MainActor
    private func enqueueFanCommand(_ command: FanCommand) {
        pendingFanCommand = command
        guard !fanCommandInFlight else { return }
        fanCommandInFlight = true
        drainFanCommandQueue()
    }

    @MainActor
    private func drainFanCommandQueue() {
        guard let command = pendingFanCommand else {
            fanCommandInFlight = false
            return
        }
        pendingFanCommand = nil
        let executor = self.executor

        Task.detached { [weak self, executor] in
            do {
                try executor.execute(command)
            } catch {
                // Daemon rejected us because a CLI hold owns the fans. Latch it
                // immediately, but publish the state on MainActor.
                if let state = try? DaemonClient().readState(), state.isCLIHold {
                    await self?.latchExternalHold(state)
                }
            }
            await self?.fanCommandFinished()
        }
    }

    @MainActor
    private func fanCommandFinished() {
        drainFanCommandQueue()
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
        // orphaned; the Smart tick then establishes supervised control.
        if took { try? executor.execute(.resetAuto) }
        TFLogger.shared.profile("Smart activated")
    }

    func resetAuto() {
        seizeControl()
        do {
            // resetAuto clears any hold (CLI or app) → daemon .none. This is the
            // no-CLI-knowledge way out of a pinned CLI hold: the Default button.
            try executor.execute(.resetAuto)
            activeProfile = .silent
            monitor?.switchProfile(.silent)
            TFLogger.shared.profile("Reset to Default (Silent (Apple Default))")
        } catch {
            TFLogger.shared.error("Reset to Default failed: \(error)")
        }
    }

    func selectProfile(_ profile: FanProfile) {
        let took = seizeControl()
        activeProfile = profile
        monitor?.switchProfile(profile)
        TFLogger.shared.profile("Selected: \(profile.name)")

        do {
            // Reset to auto when switching to a hands-off profile, OR when taking
            // over a CLI hold (so its unsupervised hold isn't orphaned). Otherwise
            // active profiles let tick() ramp from the current temperature.
            if profile.curve.handsOff || profile.id == "smart" || profile.id == "silent" || took {
                try executor.execute(.resetAuto)
            }
        } catch {
            TFLogger.shared.error("Profile \(profile.name) failed: \(error)")
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
