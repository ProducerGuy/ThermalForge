//
//  DaemonLog.swift
//  ThermalForge
//
//  The daemon's unified-log channel. Since the 26 SDKs, NSLog's dynamic data is
//  recorded as <private>, which hid every daemon diagnostic: the socket path,
//  verbs, temperatures, errno values. Everything here is logged public — nothing
//  the daemon logs needs hiding from the Mac's own admin (owner decision).
//  Unified log only; the daemon writes no log files through this channel.
//

import os

enum DaemonLog {
    static let subsystem = "com.thermalforge.daemon"
    private static let logger = Logger(subsystem: subsystem, category: "daemon")

    static func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
