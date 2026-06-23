//
//  CommandCoalescer.swift
//  ThermalForge
//
//  Serializes work off the calling thread and coalesces bursts: only the most
//  recent submitted command is ever handled. Used for the fan-control path,
//  where the monitor can emit ~10 commands/second during a ramp while each
//  daemon round-trip takes longer than a tick — without coalescing those would
//  pile up unboundedly and (if run on the main actor) freeze the UI.
//

import Foundation

public final class CommandCoalescer<Command>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let handler: (Command) -> Void

    private let lock = NSLock()
    private var pending: Command?
    private var draining = false

    public init(label: String, handler: @escaping (Command) -> Void) {
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.handler = handler
    }

    /// Submit a command. Returns immediately — never runs `handler` on the
    /// caller's thread. If a drain is already in flight the command just
    /// replaces any not-yet-handled `pending` one (latest wins).
    public func submit(_ command: Command) {
        lock.lock()
        pending = command
        let alreadyDraining = draining
        draining = true
        lock.unlock()

        guard !alreadyDraining else { return }
        queue.async { [self] in drain() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let command = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            handler(command)
        }
    }
}
