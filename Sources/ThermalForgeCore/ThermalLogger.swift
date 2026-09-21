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
    private let noExpire: Bool

    private var csvHandle: FileHandle?
    private var metadata: LogSessionMetadata
    private var sampleCount = 0
    private var running = true
    private let condition = NSCondition()
    private let retention: LogSessionRetention
    private let writer: CaptureLogWriter
    private let isoFormatter = ISO8601DateFormatter()

    public var onSample: ((String) -> Void)?

    public init(fanControl: FanControl, rateHz: Double = 1.0, duration: TimeInterval? = nil,
                outputDir: URL? = nil, noExpire: Bool = false) throws {
        guard rateHz.isFinite, rateHz > 0 else {
            throw NSError(domain: "ThermalLogger", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Sample rate must be finite and positive."])
        }
        self.fanControl = fanControl
        self.sampleInterval = 1.0 / rateHz
        self.duration = duration
        self.noExpire = noExpire || outputDir != nil
        writer = CaptureLogWriter(limit: self.noExpire ? nil : 100 * 1024 * 1024)

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
        let dirName = "thermalforge_log_\(timestamp)-\(UUID().uuidString)"

        if let custom = outputDir {
            self.outputDir = custom.appendingPathComponent(dirName)
        } else {
            let defaultDir = LogSessionRetention.defaultDirectory
            self.outputDir = defaultDir.appendingPathComponent(dirName)
        }

        retention = try LogSessionRetention(directory: self.outputDir, permanent: self.noExpire)

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
        condition.lock(); running = false; condition.broadcast(); condition.unlock()
    }

    private var isRunning: Bool {
        condition.lock(); defer { condition.unlock() }; return running
    }
    private func waitForSample(since start: Date) {
        let remaining = duration.map { max(0, $0 - Date().timeIntervalSince(start)) } ?? sampleInterval
        condition.lock()
        if running { _ = condition.wait(until: Date().addingTimeInterval(min(sampleInterval, remaining))) }
        condition.unlock()
    }

    /// Run the logging loop. Blocks until duration expires, stop() is called, or interrupted.
    public func run() throws {
        defer { retention.release() }
        // Create CSV
        let csvPath = outputDir.appendingPathComponent("thermal.csv")
        FileManager.default.createFile(atPath: csvPath.path, contents: nil)
        csvHandle = try FileHandle(forWritingTo: csvPath)
        defer { try? csvHandle?.close() }

        // Create processes CSV
        let procPath = outputDir.appendingPathComponent("processes.csv")
        FileManager.default.createFile(atPath: procPath.path, contents: nil)
        let procHandle = try FileHandle(forWritingTo: procPath)
        defer { try? procHandle.close() }
        do {
            try write(to: procHandle, "timestamp,pid,name,cpu_pct\n")
            try recordSamples(processHandle: procHandle)
            try finishSession()
        } catch {
            // Preserve metadata for partial recordings; the initial expiry survives
            // even when a full disk prevents this final write.
            try? finishSession()
            throw error
        }
    }

    private func recordSamples(processHandle procHandle: FileHandle) throws {
        // Write thermal CSV header after first sample (to capture actual sensor keys)
        var headerWritten = false
        var sensorKeys: [String] = []

        let startTime = Date()

        while isRunning {
            // Check duration
            if let dur = duration, Date().timeIntervalSince(startTime) >= dur {
                break
            }

            let timestamp = isoFormatter.string(from: Date())

            // Read thermal status
            guard let status = try? fanControl.status() else {
                waitForSample(since: startTime)
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
                try write(to: csvHandle, header + "\n")
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
            try write(to: csvHandle, row + "\n")

            // Process snapshot
            let procs = topProcesses(limit: 5)
            for proc in procs {
                try write(to: procHandle, "\(timestamp),\(proc.pid),\(proc.name),\(String(format: "%.1f", proc.cpuPct))\n")
            }

            sampleCount += 1

            // Callback
            let cpuTemp = status.temperatures
                .filter { k, _ in k.hasPrefix("TC") || k.hasPrefix("Tp") }
                .values.max() ?? 0
            let fan0 = status.fans.first.map { $0.actualRPM } ?? 0
            onSample?("[\(timestamp)] CPU: \(String(format: "%.0f", cpuTemp))°C  Fan: \(fan0) RPM  Samples: \(sampleCount)")

            waitForSample(since: startTime)
        }

    }

    private func finishSession() throws {
        metadata.endedAt = isoFormatter.string(from: Date())
        metadata.totalSamples = sampleCount

        // Write metadata JSON
        let metaPath = outputDir.appendingPathComponent("metadata.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metaData = try encoder.encode(metadata)
        try metaData.write(to: metaPath)

        try retention.finish()
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

    /// Runtime log maintenance also invokes this hourly while the app is running.
    public static func cleanExpired() {
        LogSessionRetention.cleanExpired()
    }

    // MARK: - Helpers

    private func write(to handle: FileHandle?, _ string: String) throws {
        guard let handle else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF)) }
        try writer.write(Data(string.utf8), to: handle)
    }
}
