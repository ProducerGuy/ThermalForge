//
//  DaemonClientTests.swift
//  ThermalForge
//
//  Integration tests for DaemonClient against a real Unix-domain socket server.
//  The freeze fix added a socket timeout so a stuck daemon can never block the
//  caller forever — `timesOutOnAStuckDaemon` is the regression test for it.
//

import Darwin
import Dispatch
import Foundation
import Testing

@testable import ThermalForgeCore

/// Minimal in-process Unix-socket server standing in for the privileged daemon.
/// Either replies with a fixed string or stalls (never replies) to exercise the
/// client's receive timeout. Records the commands it received.
final class FakeDaemon: @unchecked Sendable {
    enum Behavior {
        case reply(String)
        case stall
    }

    let path: String
    private let listenFD: Int32
    private let behavior: Behavior
    private let queue = DispatchQueue(label: "test.fakedaemon")
    private let lock = NSLock()
    private var receivedCommands: [String] = []
    private var stopped = false

    init?(_ behavior: Behavior) {
        self.behavior = behavior
        self.path = "/tmp/tf-test-\(UUID().uuidString.prefix(8)).sock"

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        self.listenFD = fd

        unlink(path)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        FakeDaemon.setPath(&addr, path)

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 5) == 0 else {
            close(fd)
            return nil
        }

        queue.async { [self] in acceptLoop() }
    }

    func received() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return receivedCommands
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        close(listenFD)
        unlink(path)
    }

    deinit { stop() }

    private func acceptLoop() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 { return }   // listening socket closed → done

            var buffer = [UInt8](repeating: 0, count: 256)
            let n = read(clientFD, &buffer, buffer.count - 1)
            if n > 0 {
                let cmd = String(bytes: buffer[0..<n], encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                lock.lock(); receivedCommands.append(cmd); lock.unlock()
            }

            switch behavior {
            case .reply(let response):
                let bytes = Array((response + "\n").utf8)
                _ = bytes.withUnsafeBufferPointer { write(clientFD, $0.baseAddress, $0.count) }
            case .stall:
                // Hold the connection open without replying so the client's
                // SO_RCVTIMEO fires. Bounded so the test process doesn't linger.
                Thread.sleep(forTimeInterval: 3)
            }
            close(clientFD)
        }
    }

    private static func setPath(_ addr: inout sockaddr_un, _ path: String) {
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                _ = strlcpy(dst, path, 104)
            }
        }
    }
}

@Suite("Daemon Client (integration)")
struct DaemonClientTests {

    @Test("Round-trips a successful response")
    func successfulRoundTrip() throws {
        let daemon = try #require(FakeDaemon(.reply("ok")))
        defer { daemon.stop() }

        let client = DaemonClient(socketPath: daemon.path, timeoutSeconds: 2)
        let response = try client.send("status")
        #expect(response == "ok")
    }

    @Test("Maps a daemon 'error:' reply to .commandFailed")
    func surfacesDaemonError() throws {
        let daemon = try #require(FakeDaemon(.reply("error: boom")))
        defer { daemon.stop() }

        let client = DaemonClient(socketPath: daemon.path, timeoutSeconds: 2)
        do {
            _ = try client.send("max")
            Issue.record("expected DaemonError.commandFailed")
        } catch let DaemonError.commandFailed(message) {
            #expect(message == "boom")
        }
    }

    @Test("Times out instead of hanging on a stuck daemon")
    func timesOutOnAStuckDaemon() throws {
        let daemon = try #require(FakeDaemon(.stall))
        defer { daemon.stop() }

        let client = DaemonClient(socketPath: daemon.path, timeoutSeconds: 1)
        let start = Date()
        do {
            _ = try client.send("set 3000")
            Issue.record("expected DaemonError.timedOut")
        } catch DaemonError.timedOut {
            let elapsed = Date().timeIntervalSince(start)
            // Bounded by the 1s timeout — must not block for the daemon's full stall.
            #expect(elapsed < 2.5, "send() took \(elapsed)s — timeout did not bound it")
        }
    }

    @Test("Throws .notRunning when no daemon is listening")
    func notRunningWhenNoServer() {
        let deadPath = "/tmp/tf-absent-\(UUID().uuidString.prefix(8)).sock"
        let client = DaemonClient(socketPath: deadPath, timeoutSeconds: 1)
        #expect(throws: DaemonError.self) {
            _ = try client.send("status")
        }
    }

    @Test("execute() encodes FanCommand onto the wire")
    func executeEncodesCommands() throws {
        let daemon = try #require(FakeDaemon(.reply("ok")))
        defer { daemon.stop() }

        let client = DaemonClient(socketPath: daemon.path, timeoutSeconds: 2)
        try client.execute(.setRPM(1500))
        try client.execute(.setMax)
        try client.execute(.resetAuto)

        #expect(daemon.received() == ["set 1500", "max", "auto"])
    }
}
