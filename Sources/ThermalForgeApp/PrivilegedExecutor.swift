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
    private let client: DaemonClient

    /// Serializes daemon I/O off the calling thread and coalesces bursts, so the
    /// fan-control ramp (one command per ~100ms tick, each a >0.5s daemon
    /// round-trip) can never pile up faster than the daemon drains it.
    private let coalescer: CommandCoalescer<FanCommand>

    init() {
        let client = DaemonClient()
        self.client = client
        self.coalescer = CommandCoalescer(label: "com.thermalforge.executor") { command in
            do {
                try client.execute(command)
            } catch {
                TFLogger.shared.error("Fan command failed: \(command) — \(error)")
            }
        }
    }

    /// Synchronous send — for one-off, user-initiated actions that want the
    /// error surfaced. Bounded by the daemon client's socket timeout.
    func execute(_ command: FanCommand) throws {
        try client.execute(command)
    }

    /// Fire-and-forget, coalesced, never on the calling thread.
    /// Use for the high-frequency fan-control path (monitor tick).
    func submit(_ command: FanCommand) {
        coalescer.submit(command)
    }

    var isDaemonRunning: Bool {
        ThermalForgeDaemon.isRunning
    }
}
