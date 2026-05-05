//
//  PrivilegedExecutor.swift
//  ThermalForge
//
//  Sends fan commands to the privileged daemon via Unix socket.
//  No password prompts — the daemon runs as root via launchd.
//

import Foundation
import ThermalForgeCore

final class PrivilegedExecutor: @unchecked Sendable {
    private let client = DaemonClient()

    func execute(_ command: FanCommand) throws {
        try client.execute(command)
    }

    func heartbeat() throws {
        try client.heartbeat()
    }

    var isDaemonRunning: Bool {
        ThermalForgeDaemon.isRunning
    }
}
