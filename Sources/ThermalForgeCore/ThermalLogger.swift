//
//  ThermalLogger.swift
//  ThermalForge
//
//  Research-grade thermal data logging with process correlation.
//

import Darwin
import Foundation

// MARK: - Session Metadata

public struct LogSessionMetadata: Codable {
    public let machine: String
    public let osVersion: String
    public let thermalForgeVersion: String
    public let fanCount: Int
    public let maxRPM: Int
    public let minRPM: Int
    public let sampleRateHz: Double
    public let startedAt: String
    public var endedAt: String?
    public var totalSamples: Int
    public var sensorKeys: [String]

    public init(machine: String, osVersion: String, thermalForgeVersion: String,
                fanCount: Int, maxRPM: Int, minRPM: Int, sampleRateHz: Double, startedAt: String) {
        self.machine = machine
        self.osVersion = osVersion
        self.thermalForgeVersion = thermalForgeVersion
        self.fanCount = fanCount
        self.maxRPM = maxRPM
        self.minRPM = minRPM
        self.sampleRateHz = sampleRateHz
        self.startedAt = startedAt
        self.totalSamples = 0
        self.sensorKeys = []
    }
}

// MARK: - Thermal Logger

public final class ThermalLogger {
    private let fanControl: FanControl
    private let sampleInterval: TimeInterval
    private let duration: TimeInterval?
    private let outputDir: URL
    /// The session folder as a trusted base plus components below it, for UserFiles.
    private let base: URL
    private let components: [String]
    private let files: UserFiles
    private let noExpire: Bool

    private var csvHandle: FileHandle?
    private var metadata: LogSessionMetadata
    private var sampleCount = 0
    private var running = true
    private let isoFormatter = ISO8601DateFormatter()

    public var onSample: ((String) -> Void)?

    public init(fanControl: FanControl, rateHz: Double = 1.0, duration: TimeInterval? = nil,
                outputDir: URL? = nil, noExpire: Bool = false) throws {
        self.fanControl = fanControl
        self.sampleInterval = 1.0 / rateHz
        self.duration = duration
        self.noExpire = noExpire

        // Machine info
        var sysSize = 0
        sysctlbyname("hw.model", nil, &sysSize, nil, 0)
        var modelBuf = [CChar](repeating: 0, count: max(sysSize, 1))
        sysctlbyname("hw.model", &modelBuf, &sysSize, nil, 0)
        let machine = String(cString: modelBuf)
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        let fanCount = (try? fanControl.fanCount()) ?? 0
        let fan0 = try? fanControl.fanInfo(0)

        let timestamp = isoFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dirName = "thermalforge_log_\(timestamp)"

        let location = UserDataLocation.current
        (self.base, self.components) = Self.sessionFolder(outputDir: outputDir, location: location,
                                                          dirName: dirName)
        self.outputDir = components.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
        self.files = location.files

        // A folder named with --output is the user's choice and is created as
        // named; the session folder inside it, like the default one, goes through
        // UserFiles (under sudo: the invoking user's, never through a symlink).
        if let custom = outputDir, !FileManager.default.fileExists(atPath: custom.path) {
            try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        }
        try files.ensureDirectory(base: base, components)

        self.metadata = LogSessionMetadata(
            machine: machine,
            osVersion: osVersion,
            thermalForgeVersion: ThermalForgeVersion.current,
            fanCount: fanCount,
            maxRPM: Int(fan0?.maxRPM ?? 0),
            minRPM: Int(fan0?.minRPM ?? 0),
            sampleRateHz: rateHz,
            startedAt: isoFormatter.string(from: Date())
        )
    }

    public func stop() {
        running = false
    }

    /// Run the logging loop. Blocks until duration expires, stop() is called, or interrupted.
    public func run() throws {
        // Create CSV
        csvHandle = try files.createFile(base: base, components, name: "thermal.csv")

        // Create processes CSV
        let procHandle = try files.createFile(base: base, components, name: "processes.csv")
        write(to: procHandle, "timestamp,pid,name,cpu_pct\n")

        // Write thermal CSV header after first sample (to capture actual sensor keys)
        var headerWritten = false
        var sensorKeys: [String] = []

        let startTime = Date()

        while running {
            // Check duration
            if let dur = duration, Date().timeIntervalSince(startTime) >= dur {
                break
            }

            let timestamp = isoFormatter.string(from: Date())

            // Read thermal status
            guard let status = try? fanControl.status() else {
                Thread.sleep(forTimeInterval: sampleInterval)
                continue
            }

            // First sample: write header
            if !headerWritten {
                sensorKeys = status.temperatures.keys.sorted()
                metadata.sensorKeys = sensorKeys

                var header = "timestamp"
                for i in 0..<status.fans.count {
                    header += ",fan\(i)_rpm,fan\(i)_target,fan\(i)_mode"
                }
                for key in sensorKeys {
                    header += ",\(key)"
                }
                write(to: csvHandle, header + "\n")
                headerWritten = true
            }

            // Build CSV row
            var row = timestamp
            for fan in status.fans {
                row += ",\(fan.actualRPM),\(fan.targetRPM),\(fan.mode)"
            }
            for key in sensorKeys {
                if let temp = status.temperatures[key] {
                    row += ",\(String(format: "%.1f", temp))"
                } else {
                    row += ","
                }
            }
            write(to: csvHandle, row + "\n")

            // Process snapshot
            let procs = topProcesses(limit: 5)
            for proc in procs {
                write(to: procHandle, "\(timestamp),\(proc.pid),\(proc.name),\(String(format: "%.1f", proc.cpuPct))\n")
            }

            sampleCount += 1

            // Callback
            let cpuTemp = status.temperatures
                .filter { k, _ in k.hasPrefix("TC") || k.hasPrefix("Tp") }
                .values.max() ?? 0
            let fan0 = status.fans.first.map { $0.actualRPM } ?? 0
            onSample?("[\(timestamp)] CPU: \(String(format: "%.0f", cpuTemp))°C  Fan: \(fan0) RPM  Samples: \(sampleCount)")

            Thread.sleep(forTimeInterval: sampleInterval)
        }

        // Finalize
        csvHandle?.closeFile()
        procHandle.closeFile()

        metadata.endedAt = isoFormatter.string(from: Date())
        metadata.totalSamples = sampleCount

        // Write metadata JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metaData = try encoder.encode(metadata)
        try files.writeFile(base: base, components, name: "metadata.json", data: metaData)

        // Schedule auto-delete if not --no-expire
        if !noExpire {
            scheduleCleanup()
        }
    }

    /// Output directory path
    public var outputPath: URL { outputDir }

    // MARK: - Process Snapshot

    private struct ProcSnapshot {
        let pid: Int32
        let name: String
        let cpuPct: Double
    }

    private func topProcesses(limit: Int) -> [ProcSnapshot] {
        // Use sysctl to get process list
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0

        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)

        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride

        // Get process info — we can't easily get CPU % from sysctl alone,
        // so we capture the process list and use a simpler approach
        var results: [ProcSnapshot] = []
        for i in 0..<actualCount {
            let proc = procs[i]
            let pid = proc.kp_proc.p_pid
            guard pid > 0 else { continue }

            let name = withUnsafePointer(to: proc.kp_proc.p_comm) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                    String(cString: $0)
                }
            }

            // Skip kernel/system processes
            guard !name.isEmpty, name != "kernel_task" else { continue }

            let cpuPct = Double(proc.kp_proc.p_pctcpu) / 100.0
            if cpuPct > 0 {
                results.append(ProcSnapshot(pid: pid, name: name, cpuPct: cpuPct))
            }
        }

        return results
            .sorted { $0.cpuPct > $1.cpuPct }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Cleanup

    private func scheduleCleanup() {
        // Write a marker file so we know when to clean up
        let expiry = Date().addingTimeInterval(24 * 60 * 60) // 24 hours
        try? files.writeFile(base: base, components, name: ".expires",
                             data: Data(isoFormatter.string(from: expiry).utf8))
    }

    /// Where a session's folder goes: inside the --output folder when given,
    /// otherwise in the user's data folder (UserDataLocation: under sudo, the
    /// invoking user's home).
    static func sessionFolder(outputDir: URL?, location: UserDataLocation,
                              dirName: String) -> (base: URL, components: [String]) {
        if let outputDir { return (outputDir, [dirName]) }
        return (location.home, UserDataLocation.appSupportComponents + ["logs", dirName])
    }

    /// Clean up expired log sessions
    public static func cleanExpired() {
        let location = UserDataLocation.current
        // Under sudo the folder is the invoking user's: root doesn't delete folder
        // trees there (a swapped-in link could redirect it). The app, running as
        // that user, cleans it on launch, as does `thermalforge log` without sudo.
        guard location.kind != .sudoUser else { return }
        let logsDir = location.appSupport.appendingPathComponent("logs")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: logsDir, includingPropertiesForKeys: nil
        ) else { return }

        let now = Date()
        let isoFormatter = ISO8601DateFormatter()

        for dir in contents {
            let marker = dir.appendingPathComponent(".expires")
            guard let expiryStr = try? String(contentsOf: marker, encoding: .utf8),
                  let expiry = isoFormatter.date(from: expiryStr.trimmingCharacters(in: .whitespacesAndNewlines)),
                  now > expiry
            else { continue }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Helpers

    private func write(to handle: FileHandle?, _ string: String) {
        if let data = string.data(using: .utf8) {
            handle?.write(data)
        }
    }
}
