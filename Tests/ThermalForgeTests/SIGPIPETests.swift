//
//  SIGPIPETests.swift
//  ThermalForge
//
//  A write to a socket whose peer has gone away must fail with EPIPE, never raise
//  SIGPIPE — whose default action terminates the process. Daemon side: a client sends
//  a valid frame and closes before the reply is written. Client side: the daemon closes
//  before replying. A counting handler stands in for the default action so a raised
//  SIGPIPE is observed instead of killing the test runner.
//

import Darwin
import Foundation
import Testing

@testable import ThermalForgeCore

nonisolated(unsafe) private var sigpipeCount: sig_atomic_t = 0
private func countSIGPIPE(_: Int32) { sigpipeCount += 1 }

/// Run `body` with SIGPIPE counted rather than fatal; returns how many were raised.
/// Restores the previous disposition afterwards.
private func countingSIGPIPE(_ body: () throws -> Void) rethrows -> Int {
    sigpipeCount = 0
    let previous = signal(SIGPIPE, countSIGPIPE)
    defer { signal(SIGPIPE, previous) }
    // 0 = SIG_DFL (terminate), 1 = SIG_IGN. Shows what the raised signal would have done.
    print("SIGPIPE disposition before test: \(unsafeBitCast(previous, to: Int.self))")
    try body()
    return Int(sigpipeCount)
}

extension SocketSuites {
    @Suite("SIGPIPE on a vanished peer")
    struct SIGPIPETests {

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

        @Test("Daemon: client closes before the reply is written — no SIGPIPE, daemon keeps serving")
        func daemonSurvivesVanishedClient() throws {
            let path = "/tmp/tf-sigpipe-daemon-\(getpid()).sock"
            let listenFD = bindListener(path)
            defer { close(listenFD); unlink(path) }

            // The first request parks in `handle` until the client has closed, so the
            // reply is written to a dead peer. Later requests are answered normally.
            let requestArrived = DispatchSemaphore(value: 0)
            let clientClosed = DispatchSemaphore(value: 0)
            let first = NSLock(); var isFirst = true
            // maxConnections 1: the follow-up request below can only be accepted once this
            // connection has finished, i.e. after its reply write to the dead peer completed.
            // So a served follow-up proves the write happened while SIGPIPE was being counted.
            let server = ConnectionServer(listenFD: listenFD, authorizer: FakeAuthorizer.allowAll(),
                                          maxConnections: 1,
                                          headerDeadline: SocketTestLimits.serverDeadline,
                                          requestDeadline: SocketTestLimits.serverDeadline) { _ in
                first.lock(); let park = isFirst; isFirst = false; first.unlock()
                if park {
                    requestArrived.signal()
                    clientClosed.wait()
                }
                return .versionResponse("served")
            }
            server.start()

            let frame = try DaemonProtocol.encodeFrame(DaemonRequest(verb: .version),
                                                       max: DaemonProtocol.maxRequestBytes)
            let raised = try countingSIGPIPE {
                let client = connectClient(path)
                _ = frame.withUnsafeBytes { write(client, $0.baseAddress, frame.count) }
                #expect(requestArrived.wait(timeout: .now() + SocketTestLimits.wait) == .success)
                close(client)
                clientClosed.signal()

                // The daemon must still be up and serving.
                let resp = try DaemonClient(socketPath: path).request(DaemonRequest(verb: .version),
                                                                      timeout: SocketTestLimits.wait)
                #expect(resp.version == "served")
            }
            print("SIGPIPE daemon-side: \(raised) raised")
            #expect(raised == 0)
        }

        @Test("Client: daemon closes before replying — request throws, no SIGPIPE")
        func clientSurvivesVanishedDaemon() throws {
            let path = "/tmp/tf-sigpipe-client-\(getpid()).sock"
            let listenFD = bindListener(path)
            defer { close(listenFD); unlink(path) }

            // A peer that accepts and immediately closes without reading. Whether a given
            // client write lands before or after that close is a race, so run many rounds:
            // any round where the close wins makes an unprotected write raise SIGPIPE.
            let rounds = 300
            let acceptor = Thread {
                for _ in 0..<rounds {
                    let fd = accept(listenFD, nil, nil)
                    if fd >= 0 { close(fd) }
                }
            }
            acceptor.start()

            var threw = 0
            let raised = countingSIGPIPE {
                let client = DaemonClient(socketPath: path)
                for _ in 0..<rounds {
                    // Every round must throw (no reply ever comes); a timeout throws too, so
                    // this per-round cap only bounds the loop and can't change the outcome.
                    do { _ = try client.request(DaemonRequest(verb: .version), timeout: 1.0) }
                    catch { threw += 1 }
                }
            }
            print("SIGPIPE client-side: \(raised) raised across \(rounds) rounds; \(threw) requests threw")
            #expect(threw == rounds)   // no reply ever comes — every request must fail cleanly
            #expect(raised == 0)
        }
    }
}
