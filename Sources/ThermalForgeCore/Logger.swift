//
//  Logger.swift
//  ThermalForge
//
//  Centralized logging to ~/Library/Logs/ThermalForge/thermalforge.log
//

import Foundation

public final class TFLogger {
    public static let shared = TFLogger()

    private let logDir: URL
    private let logFile: URL
    private let lock = NSLock()
    private let isoFormatter = ISO8601DateFormatter()

    /// Maximum log file size in bytes. Default 1GB.
    /// Configurable via ThermalForge config.
    public var maxFileSize: UInt64 = 1_073_741_824 // 1GB

    private init() {
        logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ThermalForge")
        logFile = logDir.appendingPathComponent("thermalforge.log")

        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
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

        // Rotate if needed
        rotateIfNeeded()

        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            if let data = entry.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            // File doesn't exist yet — create it
            try? entry.write(to: logFile, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Rotation

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
              let size = attrs[.size] as? UInt64,
              size >= maxFileSize
        else { return }

        let fm = FileManager.default
        let log2 = logDir.appendingPathComponent("thermalforge.log.2")
        let log1 = logDir.appendingPathComponent("thermalforge.log.1")

        // Remove oldest, rotate
        try? fm.removeItem(at: log2)
        if fm.fileExists(atPath: log1.path) {
            try? fm.moveItem(at: log1, to: log2)
        }
        try? fm.moveItem(at: logFile, to: log1)
    }

    // MARK: - Cleanup

    /// Delete all log files
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: logDir)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    }

    /// Path to current log file
    public var path: URL { logFile }
}
