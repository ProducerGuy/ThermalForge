//
//  PeerAuthTests.swift
//  ThermalForge
//
//  The per-connection peer check: the pure root-or-owner policy, rejection through
//  ConnectionServer (closed before any byte is read, never holding a slot), the real
//  getpeereid() path, and the bounded rejection log. Single-user safe: a real-kernel
//  rejection comes from setting ownerUID to a uid that isn't ours.
//
//  No assertion here depends on machine speed. Servers get deadlines far beyond any
//  wait, so a deadline can never stand in for the behavior under test; waits are for
//  outcomes, with a generous cap that only bounds a genuine failure.
//

import Darwin
import Foundation
import Testing

@testable import ThermalForgeCore

/// A peer check whose verdict the test decides. `allowAll` stands in where a test is
/// about something other than authentication.
struct FakeAuthorizer: PeerAuthorizing {
    let verdict: (Int32) -> PeerDecision
    func decide(fd: Int32) -> PeerDecision { verdict(fd) }
    var allowedDescription: String { "test" }

    static func allowAll() -> FakeAuthorizer {
        FakeAuthorizer { _ in .allow(PeerCredentials(uid: getuid(), gid: getgid())) }
    }
    static func rejectAll() -> FakeAuthorizer {
        FakeAuthorizer { _ in .reject(PeerCredentials(uid: 4294967294, gid: 4294967294)) }
    }
}

/// Upper bounds that only cap a genuine failure, never a pass.
enum SocketTestLimits {
    /// Longest any test waits for an outcome.
    static let wait: TimeInterval = 30
    /// Server header/request deadlines: longer than any wait, so they never fire first.
    static let serverDeadline: TimeInterval = 120
}

/// Thread-safe recorder for values produced on the server's queues, with a wait for an
/// outcome instead of a fixed sleep.
final class Box<T>: @unchecked Sendable {
    private let cond = NSCondition()
    private var items: [T] = []
    func append(_ item: T) { cond.lock(); items.append(item); cond.broadcast(); cond.unlock() }
    var all: [T] { cond.lock(); defer { cond.unlock() }; return items }

    /// Block until `done(items)` holds; false only if `cap` passes first.
    func wait(cap: TimeInterval = SocketTestLimits.wait, until done: ([T]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(cap)
        cond.lock(); defer { cond.unlock() }
        while !done(items) {
            if !cond.wait(until: deadline) { return done(items) }
        }
        return true
    }
}

extension SocketSuites {
    @Suite("Peer authentication")
    struct PeerAuthTests {

        // MARK: - Socket helpers

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

        /// Connected client with SO_NOSIGPIPE, so writing to a rejected (closed) socket
        /// fails with EPIPE instead of killing the test runner.
        private func connectClient(_ path: String) -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX); setPath(&addr, path)
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
            }
            #expect(r == 0)
            return fd
        }

        /// Start a server whose deadlines never fire within a test. The dispatch source's
        /// handler retains the server, so it lives for the rest of the process.
        private func startServer(_ listenFD: Int32, _ authorizer: any PeerAuthorizing,
                                 maxConnections: Int = 8, maxAcceptsPerEvent: Int = 64,
                                 summaryDelay: TimeInterval = 60,
                                 log: @escaping (String) -> Void = { _ in },
                                 handle: @escaping (Data) -> DaemonResponse = { _ in .versionResponse("served") }) {
            ConnectionServer(listenFD: listenFD, authorizer: authorizer,
                             maxConnections: maxConnections,
                             maxAcceptsPerEvent: maxAcceptsPerEvent,
                             headerDeadline: SocketTestLimits.serverDeadline,
                             requestDeadline: SocketTestLimits.serverDeadline,
                             summaryDelay: summaryDelay, log: log, handle: handle).start()
        }

        private func request(_ path: String) throws -> DaemonResponse {
            try DaemonClient(socketPath: path).request(DaemonRequest(verb: .version),
                                                       timeout: SocketTestLimits.wait)
        }

        /// Send a valid frame, then read. A rejected connection yields EOF (0) or
        /// ECONNRESET. The server's deadlines outlast the read timeout, so neither can come
        /// from a deadline, only from the rejection close; a timeout would read -1/EAGAIN.
        private func sendAndRead(_ fd: Int32) throws -> (n: Int, err: Int32) {
            var tv = timeval(tv_sec: Int(SocketTestLimits.wait), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let frame = try DaemonProtocol.encodeFrame(DaemonRequest(verb: .version),
                                                       max: DaemonProtocol.maxRequestBytes)
            _ = frame.withUnsafeBytes { write(fd, $0.baseAddress, frame.count) }
            var buf = [UInt8](repeating: 0, count: 64)
            let n = read(fd, &buf, buf.count)
            return (n, n < 0 ? errno : 0)
        }

        private func uniquePath(_ tag: String) -> String {
            "/tmp/tf-peer-\(tag)-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
        }

        /// The integer between `prefix` and `suffix` in `line`, if both are present.
        private static func count(in line: String, after prefix: String, before suffix: String) -> Int? {
            guard let end = line.range(of: suffix, options: .backwards),
                  let start = line.range(of: prefix, options: .backwards,
                                         range: line.startIndex..<end.lowerBound)
            else { return nil }
            return Int(line[start.upperBound..<end.lowerBound])
        }

        // MARK: 1. Pure policy

        @Test("Policy allows exactly root and the owner")
        func policy() {
            let owner: uid_t = 501
            #expect(PeerAuthorizer.allows(uid: 0, ownerUID: owner))
            #expect(PeerAuthorizer.allows(uid: owner, ownerUID: owner))
            #expect(!PeerAuthorizer.allows(uid: owner + 1, ownerUID: owner))
            #expect(!PeerAuthorizer.allows(uid: owner - 1, ownerUID: owner))
            #expect(!PeerAuthorizer.allows(uid: 4294967294, ownerUID: owner))   // nobody
            #expect(!PeerAuthorizer.allows(uid: UInt32.max, ownerUID: owner))
        }

        @Test("decide() maps credentials and errors onto allow / reject / unavailable")
        func decideMapping() {
            func authorizer(_ r: Result<PeerCredentials, PeerCredentialError>) -> PeerAuthorizer {
                PeerAuthorizer(ownerUID: 501, credentials: { _ in r })
            }
            let owner = PeerCredentials(uid: 501, gid: 20)
            let root = PeerCredentials(uid: 0, gid: 0)
            let other = PeerCredentials(uid: 502, gid: 20)
            #expect(authorizer(.success(owner)).decide(fd: -1) == .allow(owner))
            #expect(authorizer(.success(root)).decide(fd: -1) == .allow(root))
            #expect(authorizer(.success(other)).decide(fd: -1) == .reject(other))
            #expect(authorizer(.failure(PeerCredentialError(errno: ENOTCONN))).decide(fd: -1)
                    == .unavailable(errno: ENOTCONN))
        }

        // MARK: 2. Injected authorizer always rejects

        @Test("Rejected peer is closed unread: EOF, handler never runs, one log line")
        func rejectedPeerIsClosedUnread() throws {
            let path = uniquePath("reject")
            let listenFD = bindListener(path)
            defer { close(listenFD); unlink(path) }

            let handled = Box<Int>()
            let logged = Box<String>()
            startServer(listenFD, FakeAuthorizer.rejectAll(), log: { logged.append($0) }) { _ in
                handled.append(1)
                return .versionResponse("served")
            }

            let client = connectClient(path)
            defer { close(client) }
            let r = try sendAndRead(client)

            #expect(r.n == 0 || (r.n < 0 && r.err == ECONNRESET))
            #expect(logged.wait { !$0.isEmpty })
            #expect(handled.all.isEmpty)
            #expect(logged.all.count == 1)
            #expect(logged.all.first?.contains("euid 4294967294 egid 4294967294 (allowed: test)") == true)
        }

        // MARK: 3. Rejections don't use slots

        @Test("50 rejections hold no slot: the next request is still served",
              arguments: [8, 1])
        func rejectionsHoldNoSlots(maxConnections: Int) throws {
            let path = uniquePath("slots\(maxConnections)")
            let listenFD = bindListener(path)
            defer { close(listenFD); unlink(path) }

            // A rejection that held a slot would never give it back (rejected fds never
            // reach connectionFinished), and no deadline fires within the wait, so the
            // request below could only fail.
            let decisions = Box<Int>()
            let fake = FakeAuthorizer { _ in
                decisions.append(1)
                return decisions.all.count <= 50
                    ? .reject(PeerCredentials(uid: 4294967294, gid: 4294967294))
                    : .allow(PeerCredentials(uid: getuid(), gid: getgid()))
            }
            startServer(listenFD, fake, maxConnections: maxConnections)

            // Paced on the server's decisions so the test's 16-deep backlog never overflows.
            var rejected: [Int32] = []
            defer { rejected.forEach { close($0) } }
            for i in 1...50 {
                rejected.append(connectClient(path))
                #expect(decisions.wait { $0.count >= i })
            }

            let resp = try request(path)
            #expect(resp.version == "served")
            #expect(decisions.all.count == 51)
        }

        @Test("Accept cap of 1 per event still drains a queued burst: the source fires again")
        func acceptCapRefires() throws {
            let path = uniquePath("cap")
            let listenFD = bindListener(path)
            defer { close(listenFD); unlink(path) }

            // 15 connects queued in the backlog BEFORE the server starts: one readable event
            // with 15 pending, which a 1-per-event cap can only drain by firing again.
            let queued = 15
            var rejected: [Int32] = []
            defer { rejected.forEach { close($0) } }
            for _ in 0..<queued { rejected.append(connectClient(path)) }

            let decisions = Box<Int>()
            let fake = FakeAuthorizer { _ in
                decisions.append(1)
                return decisions.all.count <= queued
                    ? .reject(PeerCredentials(uid: 4294967294, gid: 4294967294))
                    : .allow(PeerCredentials(uid: getuid(), gid: getgid()))
            }
            startServer(listenFD, fake, maxAcceptsPerEvent: 1)

            let resp = try request(path)
            #expect(resp.version == "served")
            #expect(decisions.all.count == queued + 1)
        }

        // MARK: 4. Credential source fails

        @Test("Unreadable credentials are a rejection: closed, handler never runs, errno logged")
        func credentialErrorRejects() throws {
            let path = uniquePath("errno")
            let listenFD = bindListener(path)
            defer { close(listenFD); unlink(path) }

            let handled = Box<Int>()
            let logged = Box<String>()
            let authorizer = PeerAuthorizer(ownerUID: getuid(),
                                            credentials: { _ in .failure(PeerCredentialError(errno: EINVAL)) })
            startServer(listenFD, authorizer, log: { logged.append($0) }) { _ in
                handled.append(1)
                return .versionResponse("served")
            }

            let client = connectClient(path)
            defer { close(client) }
            let r = try sendAndRead(client)

            #expect(r.n == 0 || (r.n < 0 && r.err == ECONNRESET))
            #expect(logged.wait { !$0.isEmpty })
            #expect(handled.all.isEmpty)
            #expect(logged.all.first?.contains("credentials unavailable: errno \(EINVAL)") == true)
        }

        // MARK: 5–6. Real kernel credentials

        @Test("Real getpeereid: owner = our uid is served")
        func realKernelAllowsOwner() throws {
            let path = uniquePath("real-allow")
            let listenFD = bindListener(path)
            defer { close(listenFD); unlink(path) }

            startServer(listenFD, PeerAuthorizer(ownerUID: getuid()))

            let resp = try request(path)
            #expect(resp.version == "served")
        }

        @Test("Real getpeereid: owner = another uid rejects us", .enabled(if: getuid() != 0))
        func realKernelRejectsNonOwner() throws {
            let path = uniquePath("real-reject")
            let listenFD = bindListener(path)
            defer { close(listenFD); unlink(path) }

            let handled = Box<Int>()
            let logged = Box<String>()
            startServer(listenFD, PeerAuthorizer(ownerUID: getuid() + 1),
                        log: { logged.append($0) }) { _ in
                handled.append(1)
                return .versionResponse("served")
            }

            // Not served, AND the server says why: a rejection line naming our uid. A
            // request that merely timed out would leave no such line.
            #expect(throws: (any Error).self) { try request(path) }
            #expect(logged.wait { !$0.isEmpty })
            #expect(handled.all.isEmpty)
            #expect(logged.all.first?.contains("euid \(getuid()) egid \(getegid())") == true)
            #expect(logged.all.first?.contains("owner uid \(getuid() + 1)") == true)
        }

        // MARK: 7. Peer gone before the check

        @Test("Peer closed before the check: real credentials still read as our uid")
        func credentialsSurvivePeerClose() throws {
            let path = uniquePath("gone")
            let listenFD = bindListener(path)
            defer { close(listenFD); unlink(path) }

            // Connect and hang up while the connection still sits in the backlog, then start
            // the server: the check runs against a peer that no longer exists.
            let client = connectClient(path)
            close(client)

            let decisions = Box<PeerDecision>()
            let real = PeerAuthorizer(ownerUID: getuid())
            let recording = FakeAuthorizer { fd in
                let d = real.decide(fd: fd)
                decisions.append(d)
                return d
            }
            startServer(listenFD, recording)

            #expect(decisions.wait { !$0.isEmpty })
            #expect(decisions.all.first == .allow(PeerCredentials(uid: getuid(), gid: getegid())))
        }

        // MARK: 8. Bounded rejection log

        @Test("1000 rejections in one window: 5 lines, then one summary with the right count")
        func logBoundSummary() {
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            var limiter = RejectionLogLimiter(now: t0)
            var lines = 0
            for _ in 0..<1000 {
                if limiter.record("rejected", now: t0) != nil { lines += 1 }
            }
            #expect(lines == 5)
            #expect(limiter.suppressed == 995)
            #expect(limiter.flush() == "ThermalForge daemon: 995 further peer rejections suppressed")
            #expect(limiter.flush() == nil)
        }

        @Test("The suppressed count rides on the next line that gets through")
        func logBoundCarryForward() {
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            var limiter = RejectionLogLimiter(now: t0)
            for _ in 0..<1000 { _ = limiter.record("rejected", now: t0) }
            #expect(limiter.record("rejected", now: t0.addingTimeInterval(30)) == nil)   // no token yet
            #expect(limiter.record("rejected", now: t0.addingTimeInterval(61))
                    == "rejected (996 earlier rejections suppressed)")
            #expect(limiter.suppressed == 0)
        }

        @Test("Through the server: a 100-rejection flood is logged in bounded lines that account for every rejection")
        func logBoundThroughServer() throws {
            let path = uniquePath("flood")
            let listenFD = bindListener(path)
            defer { close(listenFD); unlink(path) }

            let logged = Box<String>()
            let decisions = Box<Int>()
            let rejectAll = FakeAuthorizer.rejectAll()
            let counting = FakeAuthorizer { fd in decisions.append(1); return rejectAll.decide(fd: fd) }
            let start = Date()
            startServer(listenFD, counting, summaryDelay: 0.5, log: { logged.append($0) })

            var fds: [Int32] = []
            defer { fds.forEach { close($0) } }
            for i in 1...100 {   // paced so the test's 16-deep backlog never overflows
                fds.append(connectClient(path))
                #expect(decisions.wait { $0.count >= i })
            }

            // Every rejection is accounted for exactly once: its own line, a count carried
            // on a later line, or a timed summary. Wait for that outcome, not for a time.
            func accounted(_ lines: [String]) -> Int {
                lines.reduce(0) { total, line in
                    if let n = Self.count(in: line, after: "ThermalForge daemon: ",
                                          before: " further peer rejections suppressed") {
                        return total + n
                    }
                    return total + 1 + (Self.count(in: line, after: "(", before: " earlier rejections suppressed)") ?? 0)
                }
            }
            #expect(logged.wait { accounted($0) == 100 })

            // The 5-line burst, plus at most one refill per full minute the test ran (the
            // limiter reads real time here; its exact boundaries are unit-tested above).
            let rejectionLines = logged.all.filter { $0.contains("rejected peer") }.count
            let refills = Int(Date().timeIntervalSince(start) / 60)
            #expect(rejectionLines >= 5)
            #expect(rejectionLines <= 5 + refills)
            #expect(logged.all.contains { $0.hasSuffix(" further peer rejections suppressed") })
        }
    }
}
