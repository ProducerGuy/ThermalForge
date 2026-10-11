//
//  ConnectionServerTests.swift
//  ThermalForge
//
//  Phase 4 flood case: 8 connect-and-hang sockets fill the bounded pool; a real
//  request must still be served within ~1s, freed by the header deadline. Runs against
//  a plain bound AF_UNIX socket (ConnectionServer is decoupled from the daemon's init).
//

import Darwin
import Foundation
import Testing

@testable import ThermalForgeCore

extension SocketSuites {
    @Suite("Connection server (Phase 4)")
    struct ConnectionServerTests {

        private func setPath(_ addr: inout sockaddr_un, _ path: String) {
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, path, 104) }
            }
        }

        private func bindListener(_ path: String) -> Int32 {
            unlink(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX); setPath(&addr, path)
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
            }
            #expect(r == 0)
            #expect(listen(fd, 16) == 0)
            return fd
        }

        private func connectClient(_ path: String) -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX); setPath(&addr, path)
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
            }
            #expect(r == 0)
            return fd
        }

        @Test("8 connect-and-hang sockets don't starve a real request — served within ~1s")
        func floodThenRealRequest() throws {
            let path = "/tmp/tf-conn-test.sock"
            let listenFD = bindListener(path)
            defer { close(listenFD); unlink(path) }

            let server = ConnectionServer(listenFD: listenFD, authorizer: FakeAuthorizer.allowAll(),
                                          maxConnections: 8,
                                          headerDeadline: 1.0, requestDeadline: 5.0) { _ in
                .versionResponse("served")   // prove the request was actually processed
            }
            server.start()

            // Fill the pool: 8 sockets that connect and send NOTHING.
            var hangs: [Int32] = []
            for _ in 0..<8 { hangs.append(connectClient(path)) }
            defer { hangs.forEach { close($0) } }
            Thread.sleep(forTimeInterval: 0.2)   // let the acceptor take all 8

            // A real request behind the flood.
            let client = connectClient(path)
            defer { close(client) }
            let frame = try DaemonProtocol.encodeFrame(DaemonRequest(verb: .version),
                                                       max: DaemonProtocol.maxRequestBytes)
            _ = frame.withUnsafeBytes { write(client, $0.baseAddress, frame.count) }
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            let t0 = Date()
            let body = try DaemonProtocol.readFrame(client, max: DaemonProtocol.maxResponseBytes)
            let elapsed = Date().timeIntervalSince(t0)
            let resp = try DaemonProtocol.decode(DaemonResponse.self, from: body)

            print(String(format: "FLOOD: real request served in %.3fs behind 8 connect-and-hang sockets", elapsed))
            #expect(resp.ok)
            #expect(resp.version == "served")
            #expect(elapsed < 1.3)   // freed by the ~1s header deadline, not the 5s full deadline
        }

        @Test("a slow handler past the request-body deadline still gets its reply delivered")
        func slowHandlerReplySurvives() throws {
            // The M1-M4 first manual acquisition can exceed the request-body deadline;
            // the old full-request timer then closed the connection before the reply
            // was written, and the caller reported "closed" while the command applied.
            let path = "/tmp/tf-conn-slow.sock"
            let listenFD = bindListener(path)
            defer { close(listenFD); unlink(path) }

            let server = ConnectionServer(listenFD: listenFD, authorizer: FakeAuthorizer.allowAll(),
                                          maxConnections: 8,
                                          headerDeadline: 1.0, requestDeadline: 0.5) { _ in
                Thread.sleep(forTimeInterval: 1.5)   // outlives requestDeadline
                return .versionResponse("slow-but-served")
            }
            server.start()

            let client = connectClient(path)
            defer { close(client) }
            let frame = try DaemonProtocol.encodeFrame(DaemonRequest(verb: .version),
                                                       max: DaemonProtocol.maxRequestBytes)
            _ = frame.withUnsafeBytes { write(client, $0.baseAddress, frame.count) }
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            let t0 = Date()
            let body = try DaemonProtocol.readFrame(client, max: DaemonProtocol.maxResponseBytes)
            let elapsed = Date().timeIntervalSince(t0)
            let resp = try DaemonProtocol.decode(DaemonResponse.self, from: body)

            print(String(format: "SLOW: reply for a 1.5s handler delivered in %.3fs (deadline 0.5s)", elapsed))
            #expect(resp.ok)
            #expect(resp.version == "slow-but-served")
            #expect(elapsed >= 1.4)   // the handler really did outlive the request deadline
        }

        @Test("a stalled request body is reaped at the body deadline — the slot comes back")
        func stalledBodyReaped() throws {
            // Slot-leak protection: a client that sends a header and then stalls
            // mid-body is force-closed at the request-body deadline so the next request
            // is still served. The stalled body read is async — the connection queue
            // stays free — so the deadline can and does fire. (A handler that blocks
            // the connection queue is a different animal: it also blocks its own
            // timers; handler runtime is bounded by the SMC ops' own timeouts. The
            // slow-handler test above covers the reply-survives-processing case.)
            let path = "/tmp/tf-conn-body.sock"
            let listenFD = bindListener(path)
            defer { close(listenFD); unlink(path) }

            let server = ConnectionServer(listenFD: listenFD, authorizer: FakeAuthorizer.allowAll(),
                                          maxConnections: 1,
                                          headerDeadline: 1.0, requestDeadline: 0.5,
                                          processingDeadline: 45.0) { _ in
                .versionResponse("served")
            }
            server.start()

            let t0 = Date()

            // Occupy the only slot: the header declares a 64-byte body; the body never comes.
            let stalled = connectClient(path)
            defer { close(stalled) }
            let header: [UInt8] = [0, 0, 0, 64]
            _ = header.withUnsafeBytes { write(stalled, $0.baseAddress, header.count) }
            Thread.sleep(forTimeInterval: 0.3)   // let it take the slot and parse the header

            // A real request behind it: served only once the body deadline reaps the stalled one.
            let client = connectClient(path)
            defer { close(client) }
            let frame = try DaemonProtocol.encodeFrame(DaemonRequest(verb: .version),
                                                       max: DaemonProtocol.maxRequestBytes)
            _ = frame.withUnsafeBytes { write(client, $0.baseAddress, frame.count) }
            var tv = timeval(tv_sec: 4, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            let body = try DaemonProtocol.readFrame(client, max: DaemonProtocol.maxResponseBytes)
            let resp = try DaemonProtocol.decode(DaemonResponse.self, from: body)
            let elapsed = Date().timeIntervalSince(t0)

            print(String(format: "BODY-REAP: slot reclaimed and next request served in %.3fs (deadline 0.5s)", elapsed))
            #expect(resp.ok)
            #expect(resp.version == "served")
            #expect(elapsed < 3.0)   // reaped at the ~0.5s body deadline
        }
    }
}
