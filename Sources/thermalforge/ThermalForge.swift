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

        // Remove any prior binary/symlink first. Only "nothing there" is
        // acceptable — if an existing item can't be removed, fail loud with the
        // path, or the copyItem below throws a confusing "file exists" that hides
        // the real cause. fileExists follows symlinks and returns false for a
        // dangling one (exactly the broken state a prior install could leave), so
        // check for a symlink target too.
        let somethingAtInstallPath = fm.fileExists(atPath: installPath)
            || (try? fm.destinationOfSymbolicLink(atPath: installPath)) != nil
        if somethingAtInstallPath {
            do {
                try fm.removeItem(atPath: installPath)
            } catch {
                throw ValidationError("""
                    Couldn't remove the existing binary at \(installPath):
                    \(error.localizedDescription)
                    Remove it manually (sudo rm -f "\(installPath)") and re-run.
                    """)
            }
        }

        try fm.copyItem(atPath: binaryPath, toPath: installPath)
        try fm.setAttributes(
            [.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o755],
            ofItemAtPath: installPath
        )

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

        if let appSource = candidates.first(where: { fm.fileExists(atPath: $0) }) {
            print("Using app bundle at \(appSource)")

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
        } else {
            print("Note: app bundle not found — skipping /Applications copy. Checked:")
            for path in candidates { print("  \(path)") }
            print("The CLI and daemon are installed; the menu bar app just won't be in /Applications.")
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
        try? fm.removeItem(atPath: ThermalForgeDaemon.socketPath)

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

    func run() throws {
        let fc = try FanControl()
        let server = try DaemonServer(fanControl: fc)
        server.run()
    }
}
