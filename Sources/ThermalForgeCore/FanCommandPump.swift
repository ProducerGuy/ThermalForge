//
//  FanCommandPump.swift
//  ThermalForge
//
//  Off-main, serial, coalescing pump for daemon-bound fan writes.
//

import Foundation

/// Off-main, serial, coalescing pump for fan writes. Deliberately NOT `@MainActor`,
/// and independent of HOW a command is executed (the executor is injected): it owns
/// a serial dispatch queue and a pending buffer, so callers run their socket I/O on
/// a background thread by construction — and the coalescing policy can be unit-tested
/// without a daemon. `@unchecked Sendable` because `pending` is guarded by `lock`.
public final class FanCommandPump: @unchecked Sendable {
    /// Executes one command; returns `true` on success. Runs on the pump's queue.
    public typealias Executor = @Sendable (FanCommand) -> Bool
    /// Fired (on the pump's queue) with the command's success once it runs.
    public typealias Completion = @Sendable (Bool) -> Void

    private let queue: DispatchQueue
    private let execute: Executor
    private let lock = NSLock()
    /// Fan writes awaiting the serial queue, oldest-first, each with its optional
    /// completion. Guarded by `lock`.
    private var pending: [(command: FanCommand, done: Completion?)] = []

    /// - execute: performs one command (blocking socket I/O is fine — it runs on the
    ///   pump's background queue, never the main thread) and returns whether it
    ///   succeeded. Injected so tests can supply a recording/slow stub.
    public init(
        queue: DispatchQueue = DispatchQueue(label: "com.thermalforge.command", qos: .userInitiated),
        execute: @escaping Executor
    ) {
        self.queue = queue
        self.execute = execute
    }

    /// Run a one-time launch task on the command queue BEFORE any submitted command,
    /// so a launch-time reset can never be reordered behind a later ramp write.
    public func runAtLaunch(_ block: @escaping @Sendable () -> Void) {
        queue.async(execute: block)
    }

    /// Enqueue a fan write and kick a drain. `onComplete`, if given, fires with the
    /// command's success once it runs — used by user one-shots (e.g. the Default
    /// button) that must reflect whether the write actually reached the daemon.
    ///
    /// Latest-wins coalescing, but ONLY for consecutive fire-and-forget `.setRPM`
    /// ramp commands (both the tail and the incoming one a plain `.setRPM` with no
    /// completion — a command carrying a completion is never collapsed, so its
    /// result is never lost). During a ramp setRPMs arrive ~10x/sec and each
    /// supersedes the last, so if the daemon slows and they back up, collapsing to
    /// the newest keeps the fans tracking the CURRENT target instead of replaying a
    /// stale ramp. Off-main already prevents the UI freeze; this bounds queue depth.
    ///
    /// The other three command kinds are NEVER coalesced or reordered — each is a
    /// discrete mode change, not a point on a continuum:
    ///   - `.resetAuto` hands control back to macOS; dropping it would strand the
    ///     fans in manual, and letting a later setRPM jump ahead would re-pin fans
    ///     the user asked to release.
    ///   - `.setMax` is a discrete "full blast" hold; collapsing it into an adjacent
    ///     RPM would silently lose the max request.
    ///   - `.setFan` targets ONE fan by index; a whole-system setRPM cannot stand in
    ///     for it, nor it for a setRPM.
    public func submit(_ command: FanCommand, onComplete: Completion? = nil) {
        lock.lock()
        if onComplete == nil, case .setRPM = command,
           let last = pending.last, last.done == nil, case .setRPM = last.command {
            pending[pending.count - 1] = (command, nil)   // coalesce consecutive setRPM
        } else {
            pending.append((command, onComplete))
        }
        lock.unlock()

        queue.async { [weak self] in self?.drain() }
    }

    /// Drain pending writes in order. Only one drain runs at a time (the queue is
    /// serial); extra dispatched drains find the buffer empty and return.
    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else { lock.unlock(); return }
            let (command, done) = pending.removeFirst()
            lock.unlock()
            let ok = execute(command)
            done?(ok)
        }
    }
}
