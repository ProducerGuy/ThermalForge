//
//  Logger.swift
//  ThermalForge
//
//  Daily rotating app log to ~/Library/Logs/ThermalForge/
//  One file per day (thermalforge-2026-04-05.log).
//  Auto-deletes files older than 7 days on app launch.
//

import Foundation

public final class TFLogger {
    public static let shared = TFLogger()

    private let logDir: URL
    private let lock = NSLock()
    private let isoFormatter = ISO8601DateFormatter()
    private let dateFormatter: DateFormatter

    /// How many days of logs to keep. Default 7.
    public var retentionDays: Int = 7

    /// Current day's log file (computed from today's date)
    private var currentLogFile: URL {
        let dateStr = dateFormatter.string(from: Date())
        return logDir.appendingPathComponent("thermalforge-\(dateStr).log")
    }

    private init() {
        logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ThermalForge")

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        // Clean old logs on startup
        cleanExpiredLogs()
    }

    // MARK: - Log Categories

    public func fan(_ message: String) {
        write("FAN", message)
    }

    public func profile(_ message: String) {
        write("PROFILE", message)
    }

    public func calibration(_ message: String) {
        write("CALIBRATION", message)
    }

    public func safety(_ message: String) {
        write("SAFETY", message)
    }

    public func daemon(_ message: String) {
        write("DAEMON", message)
    }

    public func error(_ message: String) {
        write("ERROR", message)
    }

    public func info(_ message: String) {
        write("INFO", message)
    }

    // MARK: - Writing

    private func write(_ category: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }

        let timestamp = isoFormatter.string(from: Date())
        let entry = "[\(timestamp)] [\(category)] \(message)\n"
        let file = currentLogFile

        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            if let data = entry.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            try? entry.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Cleanup

    /// Delete log files older than retentionDays
    private func cleanExpiredLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil) else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()

        for file in files {
            let name = file.lastPathComponent
            // Match thermalforge-YYYY-MM-DD.log pattern
            guard name.hasPrefix("thermalforge-") && name.hasSuffix(".log") else { continue }
            let dateStr = String(name.dropFirst("thermalforge-".count).dropLast(".log".count))
            guard let fileDate = dateFormatter.date(from: dateStr) else { continue }

            if fileDate < cutoff {
                try? fm.removeItem(at: file)
            }
        }

        // Also clean up the old single-file log if it exists
        let oldLog = logDir.appendingPathComponent("thermalforge.log")
        if fm.fileExists(atPath: oldLog.path) {
            try? fm.removeItem(at: oldLog)
        }
    }

    /// Delete all log files
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: logDir)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    }

    /// Path to today's log file
    public var path: URL { currentLogFile }

    /// Path to log directory
    public var directory: URL { logDir }
}
