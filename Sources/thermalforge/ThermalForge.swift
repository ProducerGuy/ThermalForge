//
//  ThermalForge.swift
//  ThermalForge
//
//  CLI entry point — fan control for Apple Silicon MacBooks.
//

import ArgumentParser
import Foundation
import Metal
import ThermalForgeCore

@main
struct ThermalForge: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thermalforge",
        abstract: "Fan control for Apple Silicon MacBooks",
        version: "0.2.0",
        subcommands: [
            Max.self,
            Auto.self,
            SetSpeed.self,
            Status.self,
            Discover.self,
            Watch.self,
            Calibrate.self,
            Log.self,
            Experiment.self,
            Install.self,
            Uninstall.self,
            Daemon.self,
        ]
    )
}

// MARK: - Max

struct Max: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "max",
        abstract: "Set all fans to maximum speed"
    )

    func run() throws {
        let fc = try FanControl()
        try fc.setMax()

        let status = try fc.status()
        for fan in status.fans {
            print("Fan \(fan.index): \(fan.actualRPM) RPM → max (\(fan.maxRPM) RPM)")
        }
    }
}

// MARK: - Auto

struct Auto: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auto",
        abstract: "Reset fans to Apple defaults"
    )

    func run() throws {
        // Kill the menu bar app first — if it's running with a profile active,
        // it will override the fan reset within seconds
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["ThermalForgeApp"]
        try? kill.run()
        kill.waitUntilExit()

        let fc = try FanControl()
        try fc.resetAuto()
        print("Fans reset to Apple defaults")
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
        let fc = try FanControl()
        let target = Float(rpm)

        if let index = fan {
            try fc.setSpeed(fan: index, rpm: target)
            print("Fan \(index) → \(rpm) RPM")
        } else {
            try fc.setAllFans(rpm: target)
            let count = try fc.fanCount()
            for i in 0..<count {
                print("Fan \(i) → \(rpm) RPM")
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
                case .coolDown: stateLabel = "cool-down"
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

        let binaryPath = ProcessInfo.processInfo.arguments[0]
        let installPath = ThermalForgeDaemon.installPath

        // Copy binary to /usr/local/bin
        let fm = FileManager.default
        try? fm.createDirectory(
            atPath: "/usr/local/bin",
            withIntermediateDirectories: true
        )
        try? fm.removeItem(atPath: installPath)
        try fm.copyItem(atPath: binaryPath, toPath: installPath)

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
        // Stop old daemon if one is running
        if ThermalForgeDaemon.isRunning {
            let unload = Process()
            unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            unload.arguments = ["bootout", "system/\(ThermalForgeDaemon.label)"]
            try unload.run()
            unload.waitUntilExit()
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Start new daemon
        let load = Process()
        load.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        load.arguments = ["bootstrap", "system", ThermalForgeDaemon.plistPath]
        try load.run()
        load.waitUntilExit()

        // Verify
        Thread.sleep(forTimeInterval: 1.0)
        guard ThermalForgeDaemon.isRunning else {
            throw ValidationError("Daemon failed to start. Try: sudo launchctl list | grep thermalforge")
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

        // Unload daemon (bootout is the modern replacement for unload)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "system/\(ThermalForgeDaemon.label)"]
        try? process.run()
        process.waitUntilExit()

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

// MARK: - Experiment

/// Controlled thermal experiment: run a workload at a fixed fan speed,
/// record temps + power every second, and write a CSV + summary.
///
/// Usage:
///   sudo thermalforge experiment --workload cpu --fan 75 --duration 5m --label "my-run"
///   sudo thermalforge experiment --workload gpu --fan smart --duration 10m
///   thermalforge experiment compare run-a run-b
struct Experiment: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "experiment",
        abstract: "Controlled thermal experiment with CSV output and comparison",
        subcommands: [Run.self, Compare.self, List.self]
    )

    // MARK: Run

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run a controlled thermal experiment"
        )

        @Option(name: .shortAndLong, help: "Workload: cpu | gpu | combined | idle")
        var workload: String = "cpu"

        @Option(name: .shortAndLong, help: "Fan: auto | max | 0-100 (percent of max RPM)")
        var fan: String = "auto"

        @Option(name: .shortAndLong, help: "Duration: 30s | 5m | 1h")
        var duration: String = "5m"

        @Option(name: .shortAndLong, help: "Human-readable label for this run")
        var label: String = ""

        @Flag(help: "Print each sample to stdout as it is recorded")
        var verbose: Bool = false

        mutating func run() throws {
            let fc = try FanControl()
            let runner = ExperimentRunner(fanControl: fc)

            let durationSecs = parseDuration(duration)
            guard durationSecs > 0 else {
                print("Invalid duration '\(duration)'. Use: 30s, 5m, 1h")
                throw ExitCode.failure
            }

            let runLabel = label.isEmpty ? "\(workload)-\(fan)-\(duration)" : label
            let isVerbose = verbose

            runner.onProgress = { msg in
                if isVerbose { print(msg) }
            }

            print("Experiment: \(runLabel)")
            print("  Workload : \(workload)")
            print("  Fan      : \(fan)")
            print("  Duration : \(durationSecs)s")
            print("Starting in 3 seconds...")
            Thread.sleep(forTimeInterval: 3)

            let result = try runner.run(
                workload: workload,
                fanSetting: fan,
                durationSecs: durationSecs,
                label: runLabel
            )

            print("\nExperiment complete.")
            print("  Output   : \(result.csvPath)")
            print("  Samples  : \(result.sampleCount)")
            print("  CPU peak : \(String(format: "%.1f", result.cpuPeak))°C")
            print("  CPU mean : \(String(format: "%.1f", result.cpuMean))°C")
            if result.throttleTimeSecs > 0 {
                print("  Throttled: \(result.throttleTimeSecs)s")
            }
            print("  Run ID   : \(result.id)")
        }

        private func parseDuration(_ s: String) -> Int {
            if s.hasSuffix("h"), let n = Int(s.dropLast()) { return n * 3600 }
            if s.hasSuffix("m"), let n = Int(s.dropLast()) { return n * 60 }
            if s.hasSuffix("s"), let n = Int(s.dropLast()) { return n }
            return Int(s) ?? 0
        }
    }

    // MARK: Compare

    struct Compare: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "compare",
            abstract: "Compare two experiment runs side by side"
        )

        @Argument(help: "First run ID or label")
        var runA: String

        @Argument(help: "Second run ID or label")
        var runB: String

        mutating func run() throws {
            let store = ExperimentStore()
            guard let a = store.load(idOrLabel: runA) else {
                print("Run '\(runA)' not found. Use 'thermalforge experiment list'.")
                throw ExitCode.failure
            }
            guard let b = store.load(idOrLabel: runB) else {
                print("Run '\(runB)' not found. Use 'thermalforge experiment list'.")
                throw ExitCode.failure
            }

            let width = 16
            func row(_ name: String, _ va: String, _ vb: String) {
                print("\(name.padding(toLength: 20, withPad: " ", startingAt: 0))"
                    + "\(va.padding(toLength: width, withPad: " ", startingAt: 0))"
                    + "\(vb)")
            }

            print("\nExperiment Comparison")
            print(String(repeating: "-", count: 56))
            row("",              a.label.prefix(14).description, b.label.prefix(14).description)
            print(String(repeating: "-", count: 56))
            row("Workload",      a.workload,         b.workload)
            row("Fan setting",   a.fanSetting,       b.fanSetting)
            row("Duration",      "\(a.durationSecs)s", "\(b.durationSecs)s")
            row("Samples",       "\(a.sampleCount)", "\(b.sampleCount)")
            row("CPU peak",      "\(String(format: "%.1f", a.cpuPeak))°C", "\(String(format: "%.1f", b.cpuPeak))°C")
            row("CPU mean",      "\(String(format: "%.1f", a.cpuMean))°C", "\(String(format: "%.1f", b.cpuMean))°C")
            row("CPU P95",       "\(String(format: "%.1f", a.cpuP95))°C",  "\(String(format: "%.1f", b.cpuP95))°C")
            row("Fan peak",      "\(a.fanPeakRPM) RPM", "\(b.fanPeakRPM) RPM")
            row("Throttle time", "\(a.throttleTimeSecs)s", "\(b.throttleTimeSecs)s")
            row("Pkg power avg", a.pkgPowerMean.map { String(format: "%.1f W", $0) } ?? "n/a",
                                 b.pkgPowerMean.map { String(format: "%.1f W", $0) } ?? "n/a")
            print(String(repeating: "-", count: 56))

            // Winner
            if a.cpuMean < b.cpuMean - 0.5 {
                print("Lower avg CPU temp: \(a.label) by \(String(format: "%.1f", b.cpuMean - a.cpuMean))°C")
            } else if b.cpuMean < a.cpuMean - 0.5 {
                print("Lower avg CPU temp: \(b.label) by \(String(format: "%.1f", a.cpuMean - b.cpuMean))°C")
            } else {
                print("CPU temperatures within 0.5°C — no significant difference.")
            }
            print("")
        }
    }

    // MARK: List

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List all saved experiment runs"
        )

        mutating func run() throws {
            let runs = ExperimentStore().all()
            if runs.isEmpty {
                print("No experiments saved. Run: thermalforge experiment run")
                return
            }
            print(String(format: "%-20s %-10s %-6s %-8s %-8s %s",
                         "Label", "Workload", "Fan", "CPU peak", "Throttle", "Date"))
            print(String(repeating: "-", count: 72))
            for r in runs.sorted(by: { $0.date < $1.date }) {
                print(String(format: "%-20s %-10s %-6s %-8s %-8s %s",
                    r.label.prefix(19).description,
                    r.workload.prefix(9).description,
                    r.fanSetting.prefix(5).description,
                    "\(String(format: "%.1f", r.cpuPeak))°C",
                    "\(r.throttleTimeSecs)s",
                    r.date.prefix(10).description))
            }
        }
    }
}

// MARK: - ExperimentResult

public struct ExperimentResult: Codable {
    public let id: String
    public let label: String
    public let workload: String
    public let fanSetting: String
    public let durationSecs: Int
    public let sampleCount: Int
    public let cpuPeak: Float
    public let cpuMean: Float
    public let cpuP95: Float
    public let fanPeakRPM: Int
    public let throttleTimeSecs: Int
    public let pkgPowerMean: Float?
    public let csvPath: String
    public let date: String
}

// MARK: - ExperimentStore

public final class ExperimentStore {
    private let dir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ThermalForge/experiments")

    public func save(_ result: ExperimentResult) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(result) {
            try? data.write(to: dir.appendingPathComponent("\(result.id).json"))
        }
    }

    public func all() -> [ExperimentResult] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(ExperimentResult.self, from: Data(contentsOf: $0)) }
    }

    public func load(idOrLabel: String) -> ExperimentResult? {
        all().first { $0.id == idOrLabel || $0.label == idOrLabel }
    }
}

// MARK: - ExperimentRunner

public final class ExperimentRunner {
    private let fanControl: FanControl
    public var onProgress: ((String) -> Void)?

    public init(fanControl: FanControl) {
        self.fanControl = fanControl
    }

    public func run(workload: String, fanSetting: String, durationSecs: Int, label: String) throws -> ExperimentResult {
        let id = UUID().uuidString.prefix(8).lowercased().description
        let isoFmt = ISO8601DateFormatter()
        let date = isoFmt.string(from: Date())

        // Set up CSV
        let store = ExperimentStore()
        let csvDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThermalForge/experiments")
        try FileManager.default.createDirectory(at: csvDir, withIntermediateDirectories: true)
        let csvURL = csvDir.appendingPathComponent("\(id)_\(label).csv")
        FileManager.default.createFile(atPath: csvURL.path, contents: nil)
        let csvHandle = try FileHandle(forWritingTo: csvURL)
        defer { csvHandle.closeFile() }

        func csvWrite(_ line: String) {
            csvHandle.write((line + "\n").data(using: .utf8)!)
        }
        csvWrite("timestamp,cpu_temp,gpu_temp,fan0_rpm,pkg_watts,thermal_state")

        // Apply fan setting
        switch fanSetting.lowercased() {
        case "max":
            try fanControl.setMax()
        case "auto":
            try fanControl.resetAuto()
        default:
            if let pct = Float(fanSetting), pct >= 0, pct <= 100 {
                let fan0 = try fanControl.fanInfo(0)
                let rpm = fan0.minRPM + (fan0.maxRPM - fan0.minRPM) * (pct / 100)
                try fanControl.setAllFans(rpm: rpm)
            }
        }

        // Start workload
        let stresser = WorkloadStresser(type: workload)
        stresser.start()
        defer {
            stresser.stop()
            try? fanControl.resetAuto()
        }

        // 5s warmup
        onProgress?("Warming up (5s)...")
        Thread.sleep(forTimeInterval: 5)

        // Sample loop
        var cpuTemps: [Float] = []
        var fanPeakRPM = 0
        var throttleSecs = 0
        var pkgWatts: [Float] = []

        onProgress?("Recording for \(durationSecs)s...")
        let deadline = Date().addingTimeInterval(TimeInterval(durationSecs))

        while Date() < deadline {
            let ts = isoFmt.string(from: Date())
            guard let status = try? fanControl.status() else {
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            let cpu = status.temperatures.filter { k, _ in k.hasPrefix("TC") || k.hasPrefix("Tp") }.values.max() ?? 0
            let gpu = status.temperatures.filter { k, _ in k.hasPrefix("TG") || k.hasPrefix("Tg") }.values.max() ?? 0
            let fan0rpm = status.fans.first?.actualRPM ?? 0
            let pkgW = status.power.packageWatts ?? 0

            cpuTemps.append(cpu)
            if fan0rpm > fanPeakRPM { fanPeakRPM = fan0rpm }
            if status.thermalPressure == .serious || status.thermalPressure == .critical { throttleSecs += 1 }
            if pkgW > 0 { pkgWatts.append(pkgW) }

            csvWrite("\(ts),\(String(format: "%.1f", cpu)),\(String(format: "%.1f", gpu)),\(fan0rpm),\(String(format: "%.1f", pkgW)),\(status.thermalPressure.rawValue)")

            Thread.sleep(forTimeInterval: 1)
        }

        // Stats
        let cpuPeak = cpuTemps.max() ?? 0
        let cpuMean = cpuTemps.isEmpty ? 0 : cpuTemps.reduce(0, +) / Float(cpuTemps.count)
        let sorted  = cpuTemps.sorted()
        let p95idx  = max(0, Int(Float(sorted.count) * 0.95) - 1)
        let cpuP95  = sorted.isEmpty ? 0 : sorted[p95idx]
        let pkgMean: Float? = pkgWatts.isEmpty ? nil : pkgWatts.reduce(0, +) / Float(pkgWatts.count)

        let result = ExperimentResult(
            id: id,
            label: label,
            workload: workload,
            fanSetting: fanSetting,
            durationSecs: durationSecs,
            sampleCount: cpuTemps.count,
            cpuPeak: cpuPeak,
            cpuMean: cpuMean,
            cpuP95: cpuP95,
            fanPeakRPM: fanPeakRPM,
            throttleTimeSecs: throttleSecs,
            pkgPowerMean: pkgMean,
            csvPath: csvURL.path,
            date: date
        )

        store.save(result)
        return result
    }
}

// MARK: - WorkloadStresser (reuses CalibrationRunner stress logic)

private final class WorkloadStresser {
    private let type: String
    private var threads: [Thread] = []
    private var running = false

    init(type: String) { self.type = type }

    func start() {
        running = true
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let doCPU = (type == "cpu" || type == "combined")
        let doGPU = (type == "gpu" || type == "combined")

        if doCPU {
            for _ in 0..<cores {
                let t = Thread { [weak self] in
                    while self?.running == true {
                        var x: Double = 1.0
                        for i in 1...10000 { x = sin(x) * cos(Double(i)) }
                        _ = x
                    }
                }
                t.qualityOfService = .userInteractive
                t.start()
                threads.append(t)
            }
        }

        if doGPU {
            // Use Metal if available — otherwise CPU-only
            startGPUStress()
        }
    }

    private func startGPUStress() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void stress(device float *d [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            float x = d[id];
            for (int i = 0; i < 2000; i++) { x = sin(x)*cos(x)+tan(x*0.01f); x = sqrt(abs(x)+1.0f); }
            d[id] = x;
        }
        """
        guard let lib = try? device.makeLibrary(source: src, options: nil),
              let fn  = lib.makeFunction(name: "stress"),
              let pip = try? device.makeComputePipelineState(function: fn),
              let queue = device.makeCommandQueue() else { return }

        let count = 1024 * 1024 * 4
        guard let buf = device.makeBuffer(length: count * 4, options: .storageModeShared) else { return }

        let t = Thread { [weak self] in
            while self?.running == true {
                guard let cb = queue.makeCommandBuffer(),
                      let enc = cb.makeComputeCommandEncoder() else { continue }
                enc.setComputePipelineState(pip)
                enc.setBuffer(buf, offset: 0, index: 0)
                let tgSize = MTLSize(width: pip.maxTotalThreadsPerThreadgroup, height: 1, depth: 1)
                enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: tgSize)
                enc.endEncoding()
                cb.commit()
                cb.waitUntilCompleted()
            }
        }
        t.qualityOfService = .userInteractive
        t.start()
        threads.append(t)
    }

    func stop() {
        running = false
        Thread.sleep(forTimeInterval: 1)
        threads.removeAll()
    }
}
