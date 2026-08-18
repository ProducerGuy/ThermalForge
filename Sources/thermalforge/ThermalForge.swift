//
//  ThermalForge.swift
//  ThermalForge
//
//  CLI entry point — fan control for Apple Silicon MacBooks.
//

import ArgumentParser
import Foundation
import ThermalForgeCore

@main
struct ThermalForge: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thermalforge",
        abstract: "Fan control for Apple Silicon MacBooks",
        version: ThermalForgeVersion.current,
        subcommands: [
            Max.self,
            Auto.self,
            SetSpeed.self,
            Status.self,
            Discover.self,
            Watch.self,
            Calibrate.self,
            Log.self,
            Install.self,
            Uninstall.self,
            Daemon.self,
            BuildApp.self,
        ]
    )
}

// MARK: - Daemon version reconciliation

/// Warn (on stderr, non-blocking) if a background daemon from a different build
/// is running. The daemon is a long-lived launchd process; after `brew upgrade`
/// it keeps running the OLD binary until `thermalforge install` re-syncs it, so
/// the menu bar app can silently diverge from this CLI. Called by every
/// fan-affecting command. Advisory only — it never blocks the command.
func warnIfDaemonVersionMismatch() {
    guard ThermalForgeDaemon.isRunning else { return }
    guard let response = try? DaemonClient().sendRaw("version") else { return }

    // A daemon that predates the `version` command answers with the literal
    // "error: unknown command 'version'" — that's a normal reply, so detect the
    // "error:" prefix and treat it as an older build rather than a version.
    let daemonVersion = response.hasPrefix("error:") ? "an older build" : response
    guard daemonVersion != ThermalForgeVersion.current else { return }

    let message = """
        ⚠️  Version mismatch: the background daemon is running \(daemonVersion), \
        but this CLI is \(ThermalForgeVersion.current).
            They're from different installs, so the menu bar app may not behave \
        like the command line until you re-sync them.
            Fix it with one command:  sudo thermalforge install

        """
    FileHandle.standardError.write(Data(message.utf8))
}

/// Emit the single stderr warning (never silent, never doubled) for a routed
/// fan command: the specific consequence when the daemon is too old to do what
/// was asked, or a plain version-mismatch nudge when it routed fine but is a
/// different build. The router already did the one version query this needs.
func reportRoute(_ route: FanRoute) {
    let message: String
    switch route {
    case .direct:
        return
    case .daemon(let version):
        // Routed and honored. Warn only if the daemon is a different build than
        // this CLI — the command worked, but the menu bar app may differ.
        let daemonVersion = version ?? "an older build"
        guard daemonVersion != ThermalForgeVersion.current else { return }
        message = """
            ⚠️  Version mismatch: the background daemon is running \(daemonVersion), \
            but this CLI is \(ThermalForgeVersion.current).
                The command was applied, but the menu bar app may not behave like \
            the command line until you re-sync.
                Fix it with one command:  sudo thermalforge install

            """
    case .daemonHoldWillRevert(let version):
        message = """
            ⚠️  The background daemon (\(version)) is too old to hold this without \
            supervision — it will revert to auto in about 15 seconds.
                Re-sync to make holds stick:  sudo thermalforge install

            """
    case .directOldDaemon(let version):
        message = """
            ⚠️  The background daemon (\(version)) is too old to route per-fan \
            commands, so this used a direct hardware write (which needs sudo).
                Re-sync to drop the sudo requirement:  sudo thermalforge install

            """
    }
    FileHandle.standardError.write(Data(message.utf8))
}

// MARK: - Max

struct Max: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "max",
        abstract: "Set all fans to maximum speed"
    )

    func run() throws {
        // Route through the daemon (no sudo) when it's running; oneshot so a
        // fire-and-forget max hold isn't reverted by the watchdog. The router
        // handles the version query and reportRoute the single mismatch warning.
        let route = try FanCommandRouter.apply(.setMax, oneshot: true)
        reportRoute(route)

        // Status readout is a read — works without root regardless of route.
        if let fc = try? FanControl(), let status = try? fc.status() {
            for fan in status.fans {
                print("Fan \(fan.index): \(fan.actualRPM) RPM → max (\(fan.maxRPM) RPM)")
            }
        }
    }
}

// MARK: - Auto

struct Auto: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auto",
        abstract: "Reset fans to Apple defaults"
    )

    @Flag(name: .long, help: """
        Also quit the menu bar app. A running app with an active profile
        re-applies its curve within seconds, so use --stop-app when the reset
        must STICK (e.g. handing control fully back to macOS). Leave it off — the
        default — when a script, benchmark, or inference run just needs to restore
        fans without closing the user's app.
        """)
    var stopApp: Bool = false

    func run() throws {
        // Only quit the menu bar app when explicitly asked. A plain fan reset must
        // not close the user's app as a side effect — callers that shell out to
        // restore fans (scripts, benchmark harnesses) would otherwise silently
        // lose their GUI. The app-override concern is real, so it's preserved
        // behind --stop-app rather than removed.
        if stopApp {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            kill.arguments = ["ThermalForgeApp"]
            try? kill.run()
            kill.waitUntilExit()
        }

        // Route through the daemon (coordinates its state, no sudo) when running;
        // resetAuto isn't a hold, so oneshot doesn't apply.
        let route = try FanCommandRouter.apply(.resetAuto, oneshot: false)
        reportRoute(route)
        print(stopApp
            ? "Menu bar app stopped; fans reset to Apple defaults"
            : "Fans reset to Apple defaults")
    }
}

// MARK: - Set

struct SetSpeed: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set fan speed to a specific RPM"
    )

    @Argument(help: "Target RPM")
    var rpm: Int

    @Option(name: .shortAndLong, help: "Fan index (default: all fans)")
    var fan: Int?

    func run() throws {
        let target = Float(rpm)

        if let index = fan {
            // Per-fan now routes through the daemon too (0.1.5 `setfan`); older
            // daemons fall back to direct SMC, which reportRoute flags.
            let route = try FanCommandRouter.apply(.setFan(index: index, rpm: target), oneshot: true)
            reportRoute(route)
            print("Fan \(index) → \(rpm) RPM")
        } else {
            let route = try FanCommandRouter.apply(.setRPM(target), oneshot: true)
            reportRoute(route)
            if let fc = try? FanControl(), let count = try? fc.fanCount() {
                for i in 0..<count {
                    print("Fan \(i) → \(rpm) RPM")
                }
            } else {
                print("All fans → \(rpm) RPM")
            }
        }
    }
}

// MARK: - Status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print current fan speeds and temperatures as JSON"
    )

    func run() throws {
        let fc = try FanControl()
        let status = try fc.status()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try encoder.encode(status)
        print(String(data: json, encoding: .utf8)!)
    }
}

// MARK: - Discover

struct Discover: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "discover",
        abstract: "Dump all SMC keys (run first on new hardware)"
    )

    @Option(name: .shortAndLong, help: "Filter keys by prefix (e.g., F for fans, T for temps)")
    var filter: String?

    @Option(name: .shortAndLong, help: "Write output to file")
    var output: String?

    func run() throws {
        let fc = try FanControl()
        let keys = fc.discover(prefix: filter)

        // Machine info
        var sysSize = 0
        sysctlbyname("hw.model", nil, &sysSize, nil, 0)
        var modelBuf = [CChar](repeating: 0, count: max(sysSize, 1))
        sysctlbyname("hw.model", &modelBuf, &sysSize, nil, 0)
        let machineModel = String(cString: modelBuf)
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        var lines: [String] = []
        lines.append("ThermalForge Key Dump")
        lines.append("Date: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Machine: \(machineModel)")
        lines.append("macOS: \(osVersion)")
        lines.append("Keys found: \(keys.count)")
        lines.append(String(repeating: "\u{2500}", count: 72))
        lines.append("Key    Type   Size  Value")
        lines.append(String(repeating: "\u{2500}", count: 72))

        for entry in keys {
            let hex = entry.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")

            var note = ""
            if entry.size == 4 && entry.bytes.count >= 4 && entry.type == "flt " {
                let floatVal = smcBytesToFloat(entry.bytes, size: entry.size)
                if entry.key.hasPrefix("F") && floatVal >= 0 && floatVal <= 10000 {
                    note = " = \(Int(floatVal)) RPM"
                } else if entry.key.hasPrefix("T") && floatVal > 0 && floatVal < 150 {
                    note = " = \(String(format: "%.1f", floatVal)) C"
                }
            } else if entry.size == 8 && entry.bytes.count >= 4 && entry.type == "ioft" {
                let floatVal = ioftBytesToFloat(entry.bytes)
                if floatVal > 0 && floatVal < 150 {
                    note = " = \(String(format: "%.1f", floatVal)) C"
                }
            } else if entry.size == 1 && !entry.bytes.isEmpty {
                note = " = \(entry.bytes[0])"
            }

            let key = entry.key.padding(toLength: 6, withPad: " ", startingAt: 0)
            let type = entry.type.padding(toLength: 6, withPad: " ", startingAt: 0)
            let sizeStr = String(repeating: " ", count: max(0, 4 - "\(entry.size)".count)) + "\(entry.size)"
            lines.append("\(key) \(type) \(sizeStr)  \(hex)\(note)")
        }

        let report = lines.joined(separator: "\n")

        if let path = output {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
            print("Wrote \(keys.count) keys to \(path)")
        } else {
            print(report)
        }
    }
}

// MARK: - Watch

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Monitor temps and auto-adjust fans based on a profile"
    )

    @Option(name: .shortAndLong, help: "Profile: silent, balanced, performance, max")
    var profile: String = "balanced"

    @Option(name: .shortAndLong, help: "Poll interval in seconds (default 0.1 = 100ms)")
    var interval: Double = 0.1

    @Flag(name: .long, help: "Output JSON on each update")
    var json: Bool = false

    func run() throws {
        warnIfDaemonVersionMismatch()
        let profiles = FanProfile.builtIn
        guard let selectedProfile = profiles.first(where: { $0.id == profile }) else {
            throw ValidationError(
                "Unknown profile '\(profile)'. Options: \(profiles.map(\.id).joined(separator: ", "))"
            )
        }

        let fc = try FanControl()
        let monitor = ThermalMonitor(fanControl: fc, profile: selectedProfile)

        print("ThermalForge watch — profile: \(selectedProfile.name)")
        print("Hardware: \(fc.hardwareInfo)")
        print("Polling every \(interval)s. Ctrl-C to stop.\n")

        // CLI runs as root, so fan commands go directly through FanControl
        monitor.onFanCommand = { command in
            switch command {
            case .setMax: try fc.setMax()
            case .setRPM(let rpm): try fc.setAllFans(rpm: rpm)
            case .setFan(let index, let rpm): try fc.setSpeed(fan: index, rpm: rpm)
            case .resetAuto: try fc.resetAuto()
            }
        }

        monitor.onUpdate = { [json] status, activeProfile, state in
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.keyEncodingStrategy = .convertToSnakeCase
                if let data = try? encoder.encode(status),
                   let line = String(data: data, encoding: .utf8)
                {
                    print(line)
                }
            } else {
                let cpuTemp = status.temperatures
                    .filter { k, _ in k.hasPrefix("TC") || k.hasPrefix("Tp") }
                    .values.max() ?? 0
                let gpuTemp = status.temperatures
                    .filter { k, _ in k.hasPrefix("TG") || k.hasPrefix("Tg") }
                    .values.max() ?? 0
                let fan0 = status.fans.first.map { $0.actualRPM } ?? 0
                let stateLabel: String
                switch state {
                case .idle: stateLabel = "idle"
                case .active(let name): stateLabel = name
                case .safetyOverride: stateLabel = "SAFETY"
                }
                let timestamp = ISO8601DateFormatter().string(from: Date())
                print("[\(timestamp)] CPU: \(String(format: "%.0f", cpuTemp))°C  GPU: \(String(format: "%.0f", gpuTemp))°C  Fan: \(fan0) RPM  [\(stateLabel)]")
            }
        }

        // Set up signal handler for clean shutdown
        signal(SIGINT) { _ in
            print("\nResetting fans to auto...")
            if let resetFC = try? FanControl() {
                try? resetFC.resetAuto()
            }
            Darwin.exit(0)
        }

        monitor.start(interval: interval)

        // Keep the process alive
        RunLoop.main.run()
    }
}

// MARK: - Calibrate

struct Calibrate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calibrate",
        abstract: "Measure this machine's thermal characteristics for the Smart profile"
    )

    @Option(name: .shortAndLong, help: "Calibration mode: quick (~14 min), standard (~32 min), optimized (until stable)")
    var mode: String = "standard"

    @Option(name: .shortAndLong, help: "Stress type: combined (CPU+GPU, default), cpu, gpu")
    var stress: String = "combined"

    @Flag(name: .long, help: "Clear calibration data and start fresh")
    var reset: Bool = false

    func run() throws {
        // Reset doesn't need sudo — it's user data
        if reset {
            if CalibrationData.exists {
                try? FileManager.default.removeItem(at: CalibrationData.filePath)
                print("Calibration data cleared. Smart will use the default curve.")
                TFLogger.shared.calibration("Calibration data reset by user")
            } else {
                print("No calibration data to clear.")
            }
            return
        }

        guard geteuid() == 0 else {
            throw ValidationError("Run with sudo: sudo thermalforge calibrate")
        }

        guard let calMode = CalibrationMode(rawValue: mode) else {
            throw ValidationError("Unknown mode '\(mode)'. Options: quick, standard, optimized")
        }

        guard let calStress = CalibrationStressType(rawValue: stress) else {
            throw ValidationError("Unknown stress type '\(stress)'. Options: combined, cpu, gpu")
        }

        // Prevent downgrade
        if CalibrationRunner.wouldDowngrade(mode: calMode) {
            let existing = CalibrationData.load()
            let existingMode = existing?.mode ?? "unknown"
            throw ValidationError(
                "Existing calibration was run at '\(existingMode)' level. " +
                "Running '\(mode)' would downgrade your data. " +
                "Use --mode \(existingMode) or higher."
            )
        }

        print("ThermalForge Calibration")
        print("========================")
        print("Mode: \(calMode.description)")
        print("Stress: \(calStress.description)")
        print("")
        print("This will stress your \(calStress == .combined ? "CPU and GPU" : calStress == .cpu ? "CPU" : "GPU") and measure thermal response at 5 fan speed levels.")
        print("Fans will be loud during the test.")
        print("")
        print("DISCLAIMER: Calibration pushes your Mac to full load and cycles fan speeds.")
        print("This is within normal operating parameters but ThermalForge is provided")
        print("as-is with no warranty. Use at your own risk.")
        print("")
        print("Press Ctrl-C at any time to stop. Fans will reset to Apple defaults.\n")

        let fc = try FanControl()
        let runner = CalibrationRunner(fanControl: fc, mode: calMode, stressType: calStress)

        // Kill switch: Ctrl-C resets fans and exits cleanly
        signal(SIGINT) { _ in
            print("\n\nCalibration interrupted. Resetting fans to Apple defaults...")
            if let resetFC = try? FanControl() {
                try? resetFC.resetAuto()
            }
            print("Fans reset. No calibration data was saved.")
            Darwin.exit(0)
        }

        runner.onProgress = { message in
            print(message)
        }

        let data = try runner.run()
        try data.save()

        print("\nCalibration complete.")
        print("\nSaved to:")
        print("  \(CalibrationData.filePath.path)")
        if let logPath = runner.logPath {
            print("  \(logPath.path)")
        }
        print("\nResults:")
        for m in data.measurements {
            print("  \(Int(m.targetTemp))°C → \(Int(m.holdingRPMPercent * 100))% fan speed")
        }
        print("\nThe Smart profile will now use these measurements for this machine.")
        if runner.logPath != nil {
            print("The CSV log contains every sensor reading taken during calibration.")
        }
    }
}

// MARK: - Log

struct Log: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log",
        abstract: "Record thermal data to CSV for research and analysis"
    )

    /// Static reference for SIGINT handler (can't capture context in C function pointer)
    nonisolated(unsafe) static var activeLogger: ThermalLogger?

    @Option(name: .shortAndLong, help: "Sample rate in Hz (default: 1)")
    var rate: Double = 1.0

    @Option(name: .shortAndLong, help: "Duration (e.g., 1h, 30m, 60s). Omit for indefinite.")
    var duration: String?

    @Option(name: .shortAndLong, help: "Output directory (default: ~/Library/Application Support/ThermalForge/logs)")
    var output: String?

    @Flag(name: .long, help: "Keep logs permanently (default: auto-delete after 24h)")
    var noExpire: Bool = false

    func run() throws {
        let fc = try FanControl()

        let durationSec: TimeInterval? = duration.flatMap { parseDuration($0) }
        let outputURL = output.map { URL(fileURLWithPath: $0) }

        let logger = try ThermalLogger(
            fanControl: fc,
            rateHz: rate,
            duration: durationSec,
            outputDir: outputURL,
            noExpire: noExpire
        )

        // Clean expired sessions on startup
        ThermalLogger.cleanExpired()

        let durationStr = durationSec.map { formatDuration($0) } ?? "indefinite"
        print("ThermalForge Log")
        print("  Rate: \(rate) Hz")
        print("  Duration: \(durationStr)")
        print("  Output: \(logger.outputPath.path)")
        print("  Auto-delete: \(noExpire ? "off" : "after 24h")")
        print("\nLogging... Ctrl-C to stop.\n")

        // Clean shutdown on Ctrl-C
        Log.activeLogger = logger
        signal(SIGINT) { _ in
            print("\n\nStopping...")
            Log.activeLogger?.stop()
            Thread.sleep(forTimeInterval: 1)
            Darwin.exit(0)
        }

        logger.onSample = { line in
            print(line)
        }

        try logger.run()

        print("\nLog saved to: \(logger.outputPath.path)")
        print("  thermal.csv   — sensor readings + fan state")
        print("  processes.csv — top processes by CPU")
        print("  metadata.json — session info + data dictionary")
    }

    private func parseDuration(_ s: String) -> TimeInterval? {
        let trimmed = s.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasSuffix("h"), let v = Double(trimmed.dropLast()) { return v * 3600 }
        if trimmed.hasSuffix("m"), let v = Double(trimmed.dropLast()) { return v * 60 }
        if trimmed.hasSuffix("s"), let v = Double(trimmed.dropLast()) { return v }
        return Double(trimmed)
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        if t >= 3600 { return "\(Int(t / 3600))h" }
        if t >= 60 { return "\(Int(t / 60))m" }
        return "\(Int(t))s"
    }
}

// MARK: - Install

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the background daemon (one-time, requires sudo)"
    )

    func run() throws {
        guard geteuid() == 0 else {
            throw ValidationError("Run with sudo: sudo thermalforge install")
        }

        // The daemon runs under launchd with no SUDO_UID of its own, so capture the
        // controlling user here and bake it into the plist (1c). Absent means
        // "already root, not via sudo" (a root shell) — refuse rather than default to
        // 0, which would make the socket root-only and brick the user's app. A
        // non-root user never reaches this line — the geteuid() guard above stops them.
        guard let sudoUIDString = ProcessInfo.processInfo.environment["SUDO_UID"],
              let ownerUID = Int(sudoUIDString), ownerUID != 0 else {
            throw ValidationError("""
                Can't determine who should own fan control: SUDO_UID isn't set.
                Run the install with sudo from your normal user account:

                    sudo thermalforge install

                Don't run it from a root shell (su / sudo -i) — the daemon needs your
                user's id so your app and CLI work without sudo. Installing as root
                would lock every non-root account out of fan control.
                """)
        }

        // Non-destructively capture whether the controlling user's app is running
        // NOW — before this install kills anything — as the signal for whether to
        // relaunch it at the end (upgrade recovery). Captured here, not inferred from
        // a later pkill, so it can't be confused by whatever killed the app first
        // (./setup.sh quits it before calling install; brew leaves it running).
        func runTool(_ path: String, _ args: [String]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            do { try p.run(); p.waitUntilExit(); return p.terminationStatus }
            catch { return -1 }
        }
        // Like runTool but returns stdout (first line, trimmed) or nil — used to
        // capture a pid so the relaunch below can confirm a genuinely NEW process.
        func runToolOutput(_ path: String, _ args: [String]) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            do { try p.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return out.split(separator: "\n").first.map(String.init)
        }
        // Capture the controlling user's app PID now — before this install kills
        // anything — both as the signal for whether to relaunch (upgrade recovery)
        // and as the baseline for confirming a real relaunch (a different pid).
        let prePid = runToolOutput("/usr/bin/pgrep", ["-x", "-u", "\(ownerUID)", "ThermalForgeApp"])
        let appWasRunning = prePid != nil

        // Resolve symlinks first. Launched via Homebrew (`sudo thermalforge
        // install`), argv[0] is /opt/homebrew/bin/thermalforge — itself a symlink
        // into the Cellar. Copying that verbatim produces a symlink whose relative
        // target (../Cellar/...) doesn't exist under /usr/local, i.e. a dangling
        // link launchd can't exec. Resolve it so the REAL binary gets copied.
        let binaryPath = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .resolvingSymlinksInPath().path
        let installPath = ThermalForgeDaemon.installPath

        // Copy the real binary to /usr/local/bin as a root-owned regular file
        // (root:wheel 0755). launchd execs this as root, so it must live on a
        // path that isn't user-writable — never a link back into /opt/homebrew/bin
        // (user-writable → a root daemon exec'ing from there is privilege
        // escalation). Always overwrite so re-running after `brew upgrade`
        // re-syncs the installed copy.
        let fm = FileManager.default
        // On a clean Apple Silicon machine /usr/local/bin may not exist. Fail
        // loud if it can't be created — silently ignoring it makes every step
        // after this fail for reasons that make no sense.
        // (createDirectory(withIntermediateDirectories: true) is a no-op if the
        // directory already exists, so this only throws on a real failure.)
        do {
            try fm.createDirectory(atPath: "/usr/local/bin", withIntermediateDirectories: true)
        } catch {
            throw ValidationError("""
                Couldn't create /usr/local/bin: \(error.localizedDescription)
                The daemon binary can't be installed without it.
                """)
        }

        // #28 self-delete + upgrade re-sync. Two separate concerns, kept separate.
        //
        // SAFETY (never brick): never remove installPath. Stage into installPath.new
        // (same directory → same filesystem → rename() is atomic, no EXDEV) and
        // rename() over installPath. The source is read into the temp before
        // installPath is touched, so a same-path or failed install can never delete
        // the binary it's reading from (#28), installPath is never absent (the
        // emergency-reset escape hatch always exists), and a dangling symlink is
        // replaced too — what the old removeItem was for.
        //
        // SOURCE (re-sync, path-independent): install the binary the user invoked
        // (argv[0]) when it's a DISTINCT file from installPath — right for a
        // from-source build (.build/release: even same version, newer code) and for
        // Homebrew-via-/opt/homebrew (the keg). When argv[0] IS installPath — re-run
        // install from the installed binary, e.g. sudo's secure_path resolving to the
        // stale /usr/local/bin copy after `brew upgrade` — copying it onto itself is a
        // permanent no-op that would leave the daemon stale and the mismatch warning
        // firing forever. So fall back to the Homebrew keg and install it IF it's a
        // newer version. The keg's version is read from its Cellar PATH (opt/<formula>
        // → Cellar/<formula>/<version>), never by executing an untrusted-path binary
        // as root — the installer only ever copies it.
        let attrs: [FileAttributeKey: Any] =
            [.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o755]
        let resolvedBinary = URL(fileURLWithPath: binaryPath).resolvingSymlinksInPath().path
        let resolvedInstall = URL(fileURLWithPath: installPath).resolvingSymlinksInPath().path

        // Atomically replace installPath with a copy of `source`, never removing
        // installPath. Throws on failure, leaving the existing install intact.
        //
        // Considered: the temp (installPath + ".new") briefly holds the SOURCE's mode
        // bits between copyItem and setAttributes. copyItem runs as root, so the temp
        // is root-OWNED throughout — only the permission bits are the source's. A
        // pre-planted temp can't redirect us: removeItem clears it first and acts on
        // the link itself, never following a symlink. setAttributes then forces
        // root:wheel 0755 and rename() is atomic, so installPath's committed state is
        // always the root-owned binary. The residual window would only matter if the
        // source binary were itself group/other-writable (ours isn't) — a
        // user-writable /usr/local/bin is the pre-existing bad state item 1's throw
        // covers, not something this staging introduces. Documented so safe-here isn't
        // mistaken for unaudited.
        func installBinary(from source: String) throws {
            // Enforce the assumption the comment above relies on rather than trusting
            // it: a group/other-writable source would briefly yield a root-owned but
            // other-writable temp in /usr/local/bin — a write-into-root-binary window.
            // Reject it up front, with the exact fix. No effect on a correctly-built
            // source (0755/0555 keg or from-source binary).
            if let perms = (try? fm.attributesOfItem(atPath: source))?[.posixPermissions] as? Int,
               perms & 0o022 != 0 {
                throw ValidationError("""
                    Refusing to install \(source): it is group/other-writable
                    (mode \(String(perms, radix: 8))). Fix with:
                        chmod go-w "\(source)"
                    """)
            }

            let tempPath = installPath + ".new"
            try? fm.removeItem(atPath: tempPath)   // clear a stale temp from a prior crash
            do {
                try fm.copyItem(atPath: source, toPath: tempPath)
                try fm.setAttributes(attrs, ofItemAtPath: tempPath)
            } catch {
                try? fm.removeItem(atPath: tempPath)
                throw ValidationError("""
                    Couldn't stage the daemon binary at \(tempPath):
                    \(error.localizedDescription)
                    The existing install at \(installPath) is untouched.
                    """)
            }
            guard rename(tempPath, installPath) == 0 else {
                let err = errno
                try? fm.removeItem(atPath: tempPath)
                throw ValidationError(
                    "Couldn't install the binary to \(installPath) (rename failed: errno \(err)). " +
                    "The existing install is untouched."
                )
            }
        }

        if resolvedBinary != resolvedInstall {
            // Install the binary the user invoked.
            try installBinary(from: binaryPath)
        } else {
            // Self-referential invocation → a re-sync request. The running binary's
            // version IS installPath's version (same file), so only a strictly-newer
            // Homebrew keg is worth installing; never downgrade.
            let current = ThermalForgeVersion.current
            let kegBinaries = [
                "/opt/homebrew/opt/thermalforge/bin/thermalforge",
                "/usr/local/opt/thermalforge/bin/thermalforge",
            ]
            // Version from the keg's resolved Cellar path — no execution. opt/<f>
            // symlinks to Cellar/<f>/<version>; take the component after it.
            func kegVersion(_ path: String) -> String? {
                let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                let parts = real.components(separatedBy: "/Cellar/thermalforge/")
                guard parts.count == 2 else { return nil }
                return parts[1].components(separatedBy: "/").first
            }

            var resynced = false
            for keg in kegBinaries {
                guard fm.fileExists(atPath: keg) else { continue }
                guard let version = kegVersion(keg) else {
                    // Keg is present but its version couldn't be read from the path —
                    // most likely the formula was renamed (the parse keys on
                    // "/Cellar/thermalforge/"). Say so loudly: otherwise re-sync goes
                    // silent and no one would know why a stale daemon won't update.
                    let resolved = URL(fileURLWithPath: keg).resolvingSymlinksInPath().path
                    print("""
                        Found a Homebrew keg at \(keg) but couldn't parse its version \
                        from the resolved path \(resolved) (expected \
                        .../Cellar/thermalforge/<version>/...). Skipping re-sync — \
                        check whether the formula was renamed.
                        """)
                    continue
                }
                // Strictly newer than what's installed (numeric, never downgrade).
                guard ThermalForgeVersion.atLeast(version, current),
                      !ThermalForgeVersion.atLeast(current, version) else { continue }
                print("Re-syncing daemon binary from Homebrew keg \(version) at \(keg).")
                try installBinary(from: URL(fileURLWithPath: keg).resolvingSymlinksInPath().path)
                resynced = true
                break
            }
            if !resynced {
                // Already current — nothing newer to install. Re-assert ownership/
                // perms and fail LOUD if it doesn't take. launchd execs installPath as
                // root at every boot, so if a prior bad state left it user-owned or
                // user-writable, a silent failure here would leave a local user able to
                // replace the root daemon binary. This is also the most common path
                // (re-install when already current), so it must not swallow errors —
                // every other write in this file throws; so does this.
                print("Binary at \(installPath) is already current (\(current)) — nothing to copy.")
                do {
                    try fm.setAttributes(attrs, ofItemAtPath: installPath)
                } catch {
                    throw ValidationError("""
                        Couldn't re-assert ownership/permissions on \(installPath):
                        \(error.localizedDescription)
                        """)
                }
            }
        }

        // Write launchd plist
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(ThermalForgeDaemon.label)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(installPath)</string>
                    <string>daemon</string>
                    <string>--owner-uid</string>
                    <string>\(ownerUID)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <true/>
            </dict>
            </plist>
            """
        try plist.write(
            toFile: ThermalForgeDaemon.plistPath,
            atomically: true, encoding: .utf8
        )
        // Tear down any existing job before bootstrapping — but only if launchd
        // actually has the label registered. Checking registration (not
        // isRunning) still catches a loaded-but-failing job that retry-loops on a
        // dead exec; skipping when nothing is registered avoids a spurious
        // "Boot-out failed: No such process" on a fresh install. A real bootout
        // failure throws.
        try ThermalForgeDaemon.bootoutIfRegistered()

        // Migration: drop the legacy world-writable /tmp socket so no old client can
        // find (or squat) it. The daemon now serves /var/run; a literal path here
        // because socketPath is /var/run/... from Phase 1a.
        //
        // Safe despite being a root unlink() of a path in a world-writable directory
        // (the classic /tmp symlink/hardlink attack surface), for three reasons:
        //   - Symlink redirect: unlink() acts on the link itself, never follows it, so
        //     a planted symlink can't make us delete its target.
        //   - Hardlink to a victim file: unlink() only removes THIS /tmp directory
        //     entry and decrements the link count — the victim file persists at its
        //     original path.
        //   - Directory planted at that name: unlink() fails with EISDIR; we ignore
        //     the return, so it's a harmless no-op.
        unlink("/tmp/thermalforge.sock")

        // Start new daemon
        let load = Process()
        load.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        load.arguments = ["bootstrap", "system", ThermalForgeDaemon.plistPath]
        try load.run()
        load.waitUntilExit()

        // Verify
        Thread.sleep(forTimeInterval: 1.0)
        guard ThermalForgeDaemon.isRunning else {
            throw ValidationError("""
                The background daemon didn't come up after install, so the menu bar
                app won't be able to control fans yet.

                What to do:
                  1. Run it again:  sudo thermalforge install
                  2. If it still fails, the copy at \(installPath) may not be
                     executable or is crashing on launch. Open Console.app, search
                     "com.thermalforge.daemon", and check the most recent error.
                """)
        }

        // Copy the menu bar app into /Applications. Homebrew's post_install is
        // sandboxed and can't write outside its prefix (EPERM on mkdir under
        // /Applications), so the copy lives here instead — we're root under sudo,
        // unsandboxed.
        //
        // Find the .app in priority order:
        //   1. Next to the running binary (<keg>/bin/thermalforge -> <keg>/ThermalForge.app):
        //      the normal `sudo thermalforge install` path, via Homebrew's bin symlink.
        //   2. Homebrew's stable opt symlink — needed when the copy that this command
        //      places in /usr/local/bin is what's run (there "up two dirs" is /usr,
        //      no app). /opt/homebrew and /usr/local are the only two Homebrew
        //      prefixes on macOS (Apple Silicon / Intel), and opt/<formula> always
        //      points at the current keg, so this stays version-independent.
        let appDest = "/Applications/ThermalForge.app"

        let nextToBinary = URL(fileURLWithPath: binaryPath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()   // <keg>/bin
            .deletingLastPathComponent()   // <keg>
            .appendingPathComponent("ThermalForge.app")
            .path

        let candidates = [
            nextToBinary,
            "/opt/homebrew/opt/thermalforge/ThermalForge.app",
            "/usr/local/opt/thermalforge/ThermalForge.app",
        ]

        // Only copy a bundle whose version matches THIS install — never a stale one
        // (a leftover Homebrew 0.1.x keg the `opt` symlink still points at) over a
        // correct /Applications bundle. On a from-source install there is no
        // pre-assembled current bundle here yet (build-app assembles it right after),
        // so reject stale candidates and leave /Applications untouched rather than
        // grab whatever exists — the bug where a direct install clobbered /Applications
        // with an old Cellar bundle.
        func bundleVersion(_ appPath: String) -> String? {
            NSDictionary(contentsOfFile: "\(appPath)/Contents/Info.plist")?["CFBundleShortVersionString"] as? String
        }
        let wantedVersion = ThermalForgeVersion.current

        // Whether a version-matching bundle was actually installed THIS run. The
        // relaunch at the end keys off this: reopening a stale /Applications bundle
        // (old /tmp socket compiled in) is exactly the daemon-down-banner bug to avoid.
        var freshBundleInstalled = false
        if let appSource = candidates.first(where: {
            fm.fileExists(atPath: $0) && bundleVersion($0) == wantedVersion
        }) {
            print("Using app bundle at \(appSource) (\(wantedVersion))")

            // Replace any existing bundle. If removal fails, FAIL LOUD — do not
            // swallow it. Homebrew silently ignoring this is exactly what left a
            // stale bundle in place and produced the nested-path confusion.
            if fm.fileExists(atPath: appDest) {
                do {
                    try fm.removeItem(atPath: appDest)
                } catch {
                    throw ValidationError(
                        "Could not remove existing \(appDest): \(error.localizedDescription). " +
                        "Remove it manually (sudo rm -rf \"\(appDest)\") and re-run."
                    )
                }
            }
            try fm.copyItem(atPath: appSource, toPath: appDest)

            // Strip quarantine/extended attributes so Gatekeeper won't block launch.
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-cr", appDest]
            try? xattr.run()
            xattr.waitUntilExit()

            print("Installed ThermalForge.app to \(appDest)")
            freshBundleInstalled = true
        } else {
            print("Note: no \(wantedVersion) app bundle found — leaving /Applications untouched. Checked:")
            for path in candidates {
                let tag = bundleVersion(path) ?? (fm.fileExists(atPath: path) ? "unreadable" : "absent")
                print("  \(path)  [\(tag)]")
            }
            print("The CLI and daemon are installed. A from-source build assembles the app next (build-app); otherwise reinstall via ./setup.sh or Homebrew.")
        }

        // Upgrade recovery: if the controlling user's app was running when this
        // install STARTED (captured above, before anything killed it), it has the OLD
        // /tmp socket path compiled in and would now connect to the removed /tmp and
        // show the misleading daemon-down banner. Restart it so it reloads the new
        // binary + /var/run path. appWasRunning also confirms a live GUI session to
        // relaunch into (a menu bar app only runs in one) — a not-logged-in user
        // (app not running) is a clean no-op. ENTIRELY non-fatal: the daemon is
        // already verified up, so a failed GUI relaunch prints guidance and never
        // fails the install.
        let moveGuidance = "Quit and reopen ThermalForge — the fan-control socket moved this version."
        if appWasRunning && freshBundleInstalled {
            _ = runTool("/usr/bin/pkill", ["-x", "-u", "\(ownerUID)", "ThermalForgeApp"])
            Thread.sleep(forTimeInterval: 0.5)   // let it fully exit before relaunch
            _ = runTool("/bin/launchctl",
                ["asuser", "\(ownerUID)", "/usr/bin/open", appDest])
            // Don't trust open's exit code — on some macOS versions it returns 0
            // without launching into the GUI session. Confirm a genuinely NEW app
            // pid (different from the one captured before install) actually appeared;
            // if pkill failed and the old app survived, the pid is unchanged and we
            // fall through to the guidance rather than claim a relaunch.
            // Poll for a genuinely new pid instead of sleeping a fixed interval and
            // hoping — the app can register slower than any single guess, which would
            // print the guidance on a successful relaunch. Up to ~5 checks at 0.5s,
            // stopping the moment a pid different from prePid appears.
            var relaunched = false
            for _ in 0..<5 {
                Thread.sleep(forTimeInterval: 0.5)
                if let newPid = runToolOutput("/usr/bin/pgrep", ["-x", "-u", "\(ownerUID)", "ThermalForgeApp"]),
                   newPid != prePid {
                    relaunched = true
                    break
                }
            }
            if !relaunched {
                print(moveGuidance)
            }
        } else if appWasRunning {
            // App was running but NO fresh bundle was installed this run, so
            // /Applications holds a stale (or missing) bundle with the old /tmp socket
            // compiled in. Reopening it would only reproduce the daemon-down banner —
            // tell the user instead of relaunching the wrong binary.
            print(moveGuidance)
        }

        print("Done.")
    }
}

// MARK: - Uninstall

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove the background daemon"
    )

    func run() throws {
        guard geteuid() == 0 else {
            throw ValidationError("Run with sudo: sudo thermalforge uninstall")
        }

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // Kill app if running
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["ThermalForgeApp"]
        try? kill.run()
        kill.waitUntilExit()

        // Reset fans
        if let fc = try? FanControl() {
            try? fc.resetAuto()
        }

        // Unload the daemon if it's registered. Surface a genuine bootout failure
        // but keep going — uninstall's job is to remove everything regardless.
        do {
            try ThermalForgeDaemon.bootoutIfRegistered()
        } catch {
            FileHandle.standardError.write(Data("Warning: \(error) — continuing removal.\n".utf8))
        }

        // Remove daemon files
        try? fm.removeItem(atPath: ThermalForgeDaemon.plistPath)
        try? fm.removeItem(atPath: ThermalForgeDaemon.installPath)
        try? fm.removeItem(atPath: ThermalForgeDaemon.socketPath)      // /var/run (current)
        try? fm.removeItem(atPath: "/tmp/thermalforge.sock")           // legacy path (pre-Phase 1)

        // Remove user data
        let appSupport = home.appendingPathComponent("Library/Application Support/ThermalForge")
        let logs = home.appendingPathComponent("Library/Logs/ThermalForge")
        try? fm.removeItem(at: appSupport)
        try? fm.removeItem(at: logs)

        // Remove app bundle
        try? fm.removeItem(atPath: "/Applications/ThermalForge.app")

        print("ThermalForge fully uninstalled.")
        print("Removed: daemon, binary, app, calibration data, logs.")
    }
}

// MARK: - BuildApp (internal)

/// Assembles ThermalForge.app from a built app binary + icon, writing the
/// Info.plist from ThermalForgeVersion.current. This is the SINGLE place the
/// bundle is assembled — both install paths (Homebrew formula and setup.sh)
/// call it, so no field (version included) can drift between them.
struct BuildApp: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-app",
        abstract: "Assemble ThermalForge.app from a built app binary and icon (internal)",
        shouldDisplay: false
    )

    @Option(name: .long, help: "Path to the built ThermalForgeApp executable")
    var binary: String

    @Option(name: .long, help: "Path to the .icns app icon")
    var icon: String

    @Option(name: .long, help: "Destination .app bundle path (created or replaced)")
    var dest: String

    func run() throws {
        let fm = FileManager.default

        guard fm.fileExists(atPath: binary) else {
            throw ValidationError("App binary not found: \(binary)")
        }
        guard fm.fileExists(atPath: icon) else {
            throw ValidationError("Icon not found: \(icon)")
        }

        let contents = "\(dest)/Contents"
        let macOSDir = "\(contents)/MacOS"
        let resources = "\(contents)/Resources"

        // Replace any existing bundle so a rebuild is clean.
        if fm.fileExists(atPath: dest) {
            try fm.removeItem(atPath: dest)
        }
        try fm.createDirectory(atPath: macOSDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: resources, withIntermediateDirectories: true)

        try fm.copyItem(atPath: binary, toPath: "\(macOSDir)/ThermalForgeApp")
        try fm.copyItem(atPath: icon, toPath: "\(resources)/AppIcon.icns")

        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleName</key>
                <string>ThermalForge</string>
                <key>CFBundleDisplayName</key>
                <string>ThermalForge</string>
                <key>CFBundleIdentifier</key>
                <string>com.thermalforge.app</string>
                <key>CFBundleVersion</key>
                <string>\(ThermalForgeVersion.current)</string>
                <key>CFBundleShortVersionString</key>
                <string>\(ThermalForgeVersion.current)</string>
                <key>CFBundleExecutable</key>
                <string>ThermalForgeApp</string>
                <key>CFBundleIconFile</key>
                <string>AppIcon</string>
                <key>CFBundlePackageType</key>
                <string>APPL</string>
                <key>LSMinimumSystemVersion</key>
                <string>\(ThermalForgeVersion.minimumMacOS)</string>
                <key>LSUIElement</key>
                <true/>
                <key>NSHighResolutionCapable</key>
                <true/>
            </dict>
            </plist>
            """
        try plist.write(toFile: "\(contents)/Info.plist", atomically: true, encoding: .utf8)

        print("Assembled \(dest) (version \(ThermalForgeVersion.current))")
    }
}

// MARK: - Daemon

struct Daemon: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Run the privileged socket server (called by launchd)"
    )

    /// uid of the controlling user, injected by Install.run() into the launchd
    /// plist's ProgramArguments. Required: the daemon has no SUDO_UID of its own,
    /// so without this it can't know who owns the socket. Absent → parse failure →
    /// visible crash-loop under KeepAlive (never a silent root-owned socket).
    @Option(name: .customLong("owner-uid"), help: "uid that owns the control socket")
    var ownerUid: Int

    func run() throws {
        let fc = try FanControl()
        let server = try DaemonServer(fanControl: fc, ownerUID: uid_t(ownerUid))
        server.run()
    }
}
