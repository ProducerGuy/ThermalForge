//
//  ConnectionServer.swift
//  ThermalForge
//
//  Phase 4 connection layer: concurrent, bounded accept + one framed request/response
//  per connection over DispatchIO, with a ~1s header deadline and a ~5s full-request
//  deadline (replacing Phase 0's SO_RCVTIMEO). Decoupled from DaemonServer so it can be
//  tested against a plain bound AF_UNIX socket — the daemon's request processing is
//  injected as `handle`. Framing-level replies (legacy peer, oversized) live here; the
//  verb dispatch does not.
//

import Darwin
import Foundation

final class ConnectionServer: @unchecked Sendable {
    private let listenFD: Int32
    private let maxConnections: Int
    private let headerDeadline: TimeInterval
    private let requestDeadline: TimeInterval
    /// Processes a decoded request body → response. DaemonServer wraps its call in
    /// smcLock, so it's safe under the concurrent handlers here.
    private let handle: (Data) -> DaemonResponse

    private let acceptQueue = DispatchQueue(label: "com.thermalforge.accept")
    private var acceptSource: DispatchSourceRead?
    private var activeConnections = 0   // acceptQueue-confined
    private var accepting = true        // acceptQueue-confined

    init(listenFD: Int32,
         maxConnections: Int = 8,
         headerDeadline: TimeInterval = 1.0,
         requestDeadline: TimeInterval = 5.0,
         handle: @escaping (Data) -> DaemonResponse) {
        self.listenFD = listenFD
        self.maxConnections = maxConnections
        self.headerDeadline = headerDeadline
        self.requestDeadline = requestDeadline
        self.handle = handle
    }

    /// Accept via a DispatchSource on the (non-blocking) listen fd, bounded to
    /// maxConnections concurrent handlers. At capacity we suspend accepting; a finishing
    /// connection resumes it — pending connects wait in the listen backlog (queueing).
    func start() {
        _ = fcntl(listenFD, F_SETFL, fcntl(listenFD, F_GETFL, 0) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: acceptQueue)
        source.setEventHandler { [self] in
            while activeConnections < maxConnections {
                let clientFD = accept(listenFD, nil, nil)
                if clientFD < 0 { break }   // EAGAIN (no more pending) or error
                activeConnections += 1
                handleConnection(clientFD)
            }
            if activeConnections >= maxConnections, accepting {
                accepting = false
                source.suspend()
            }
        }
        // Assign BEFORE resume(): resume can fire the handler on acceptQueue immediately,
        // which may accept 8 and suspend; if a connection then finishes before this
        // assignment, connectionFinished() would read acceptSource as nil and never
        // resume — a permanent, timing-dependent accept stall. Assigning first also
        // establishes the happens-before so the acceptQueue reads see it.
        acceptSource = source
        source.resume()
    }

    private func connectionFinished() {
        activeConnections -= 1
        if !accepting, activeConnections < maxConnections {
            accepting = true
            acceptSource?.resume()
        }
    }

    /// One request/response per connection. A per-connection SERIAL queue serializes this
    /// connection's reads/writes/timers (they never race); different connections run
    /// concurrently. The header deadline closes a connect-and-hang fast (freeing its slot
    /// so a queued request isn't starved); the full deadline bounds a slow/partial body.
    private func handleConnection(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        let q = DispatchQueue(label: "com.thermalforge.conn")
        let io = DispatchIO(type: .stream, fileDescriptor: fd, queue: q) { [self] _ in
            close(fd)
            acceptQueue.async { self.connectionFinished() }
        }

        let headerTimeout = DispatchWorkItem { io.close(flags: .stop) }
        q.asyncAfter(deadline: .now() + headerDeadline, execute: headerTimeout)

        readExactly(io, length: 4, queue: q) { [self] header in
            headerTimeout.cancel()
            guard let header else { io.close(flags: .stop); return }

            // The full-request deadline bounds everything from here THROUGH the final
            // write. It is cancelled only in `finish`, AFTER the write completes — so a
            // client that sends a header then never reads its reply can't hang the
            // connection (and leak its slot): the deadline force-closes it. Every
            // terminal path routes through `finish`, so io is closed exactly once and
            // the DispatchIO cleanup handler runs connectionFinished exactly once.
            let fullTimeout = DispatchWorkItem { io.close(flags: .stop) }
            q.asyncAfter(deadline: .now() + requestDeadline, execute: fullTimeout)
            let finish = { fullTimeout.cancel(); io.close(flags: .stop) }

            switch DaemonProtocol.classifyHeader(header, max: DaemonProtocol.maxRequestBytes) {
            case .legacyPeer:
                // Reply in the pre-Phase-2 client's own "error:" format (raw, not a frame)
                // so its hasPrefix("error:") surfaces guidance instead of misreading a frame.
                NSLog("ThermalForge daemon: legacy (pre-Phase-2) client — advising reinstall")
                writeRaw(io, "error: daemon protocol updated; reinstall the CLI: sudo thermalforge install\n",
                         queue: q, completion: finish)
            case .oversized:
                NSLog("ThermalForge daemon: rejected oversized request frame")
                writeResponse(io, .failure(.usage, "request exceeds \(DaemonProtocol.maxRequestBytes) bytes"),
                              queue: q, completion: finish)
            case .length(let len):
                readExactly(io, length: len, queue: q) { [self] body in
                    guard let body else { finish(); return }
                    autoreleasepool {   // v0.1.10 hygiene, now per request
                        let response = handle(Data(body))
                        writeResponse(io, response, queue: q, completion: finish)
                    }
                }
            }
        }
    }

    /// Read exactly `length` bytes via DispatchIO; nil on EOF/error/short read.
    private func readExactly(_ io: DispatchIO, length: Int, queue: DispatchQueue,
                             completion: @escaping ([UInt8]?) -> Void) {
        if length == 0 { completion([]); return }
        var acc = [UInt8](); acc.reserveCapacity(length)
        io.read(offset: 0, length: length, queue: queue) { done, data, error in
            if let data, !data.isEmpty { acc.append(contentsOf: data) }
            if done { completion(error == 0 && acc.count == length ? acc : nil) }
        }
    }

    private func writeResponse(_ io: DispatchIO, _ response: DaemonResponse, queue: DispatchQueue,
                               completion: @escaping () -> Void) {
        guard let frame = try? DaemonProtocol.encodeFrame(response, max: DaemonProtocol.maxResponseBytes) else {
            NSLog("ThermalForge daemon: response exceeds frame cap; dropping connection")
            completion(); return
        }
        writeBytes(io, frame, queue: queue, completion: completion)
    }

    private func writeRaw(_ io: DispatchIO, _ string: String, queue: DispatchQueue,
                          completion: @escaping () -> Void) {
        writeBytes(io, Array(string.utf8), queue: queue, completion: completion)
    }

    private func writeBytes(_ io: DispatchIO, _ bytes: [UInt8], queue: DispatchQueue,
                            completion: @escaping () -> Void) {
        let data = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        io.write(offset: 0, data: data, queue: queue) { done, _, _ in
            if done { completion() }
        }
    }
}
