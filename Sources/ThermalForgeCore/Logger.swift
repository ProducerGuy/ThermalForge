//
//  Logger.swift
//  ThermalForge
//
//  Daily rotating app log to ~/Library/Logs/ThermalForge/
//  One file per day (thermalforge-2026-04-05.log).
//  Auto-deletes files older than 7 days on app launch.
//
//  Running as root (the daemon, or the CLI under sudo) it writes no files: its
//  messages go to the unified log instead (RootLog, public). A file log there
//  would land under root's home, where the user never looks and nothing prunes it.
//

import Darwin
import Foundation
import os

/// The unified-log channel for TFLogger in a process running as root, which in
/// practice is the CLI under sudo (the daemon's own lines go through DaemonLog).
/// Its own subsystem, so a log reader can tell a sudo command from the daemon.
/// Public, like the daemon's log: nothing here needs hiding from the Mac's admin.
enum RootLog {
    static let subsystem = "com.thermalforge.cli"
    static let category = "root"
    private static let logger = Logger(subsystem: subsystem, category: category)

    static func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}

public final class TFLogger {
    public static let shared = TFLogger()

    /// Where this process's messages go, decided once from its effective user.
    enum Destination: Equatable {
        /// Daily files in this folder (the app, and the CLI as the user).
        case files(URL)
        /// The unified log only (any process running as root).
        case unifiedLog
    }

    static func destination(euid: uid_t, home: URL) -> Destination {
        euid == 0 ? .unifiedLog : .files(home.appendingPathComponent("Library/Logs/ThermalForge"))
    }

    let destination: Destination
    /// Where root-mode lines go: the unified log. Tests swap it to capture lines
    /// without writing to the Mac's log.
    var unifiedLogSink: (_ line: String, _ isError: Bool) -> Void = { line, isError in
        if isError { RootLog.error(line) } else { RootLog.notice(line) }
    }
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

    init(euid: uid_t = geteuid(), home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        destination = Self.destination(euid: euid, home: home)
        logDir = home.appendingPathComponent("Library/Logs/ThermalForge")

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        // As root, nothing on disk: no folder, no cleanup.
        guard destination != .unifiedLog else { return }

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
        guard destination != .unifiedLog else {
            unifiedLogSink("ThermalForge CLI (root) [\(category)]: \(message)", category == "ERROR")
            return
        }

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
        guard destination != .unifiedLog else { return }
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
