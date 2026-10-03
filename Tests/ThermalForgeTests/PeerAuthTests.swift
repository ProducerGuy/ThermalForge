//
//  PeerAuthTests.swift
//  ThermalForge
//
//  The per-connection peer check: the pure root-or-owner policy, rejection through
//  ConnectionServer (closed before any byte is read, never holding a slot), the real
//  getpeereid() path, and the bounded rejection log. Single-user safe: a real-kernel
//  rejection comes from setting ownerUID to a uid that isn't ours.
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

/// Thread-safe counter/recorder for values produced on the server's queues.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

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

    private func versionFrame() throws -> [UInt8] {
        try DaemonProtocol.encodeFrame(DaemonRequest(verb: .version), max: DaemonProtocol.maxRequestBytes)
    }

    /// Send a valid frame, then read: a rejected connection yields EOF (0) or
    /// ECONNRESET, never a reply. Returns the read result and how long it took.
    private func sendAndRead(_ fd: Int32) throws -> (n: Int, err: Int32, elapsed: TimeInterval) {
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let frame = try versionFrame()
        let t0 = Date()
        _ = frame.withUnsafeBytes { write(fd, $0.baseAddress, frame.count) }
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(fd, &buf, buf.count)
        let err = n < 0 ? errno : 0
        return (n, err, Date().timeIntervalSince(t0))
    }

    private func uniquePath(_ tag: String) -> String {
        "/tmp/tf-peer-\(tag)-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
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

    @Test("Rejected peer gets EOF fast and the handler never runs")
    func rejectedPeerIsClosedUnread() throws {
        let path = uniquePath("reject")
        let listenFD = bindListener(path)
        defer { close(listenFD); unlink(path) }

        let handled = Box<Int>()
        let logged = Box<String>()
        let server = ConnectionServer(listenFD: listenFD, authorizer: FakeAuthorizer.rejectAll(),
                                      log: { logged.append($0) }) { _ in
            handled.append(1)
            return .versionResponse("served")
        }
        server.start()

        let client = connectClient(path)
        defer { close(client) }
        let r = try sendAndRead(client)

        #expect(r.n == 0 || (r.n < 0 && r.err == ECONNRESET))
        #expect(r.elapsed < 0.5)   // closed on accept, not by the 1s header deadline
        Thread.sleep(forTimeInterval: 0.1)
        #expect(handled.all.isEmpty)
        #expect(logged.all.count == 1)
        #expect(logged.all.first?.contains("euid 4294967294 egid 4294967294 (allowed: test)") == true)
    }

    // MARK: 3. Rejections don't use slots

    @Test("50 rejections hold no slot: the next request is served inside the header deadline",
          arguments: [8, 1])
    func rejectionsHoldNoSlots(maxConnections: Int) throws {
        let path = uniquePath("slots\(maxConnections)")
        let listenFD = bindListener(path)
        defer { close(listenFD); unlink(path) }

        let decisions = Box<Int>()
        let decided = DispatchSemaphore(value: 0)
        let fake = FakeAuthorizer { _ in
            decisions.append(1)
            decided.signal()
            return decisions.all.count <= 50
                ? .reject(PeerCredentials(uid: 4294967294, gid: 4294967294))
                : .allow(PeerCredentials(uid: getuid(), gid: getgid()))
        }
        let server = ConnectionServer(listenFD: listenFD, authorizer: fake,
                                      maxConnections: maxConnections,
                                      headerDeadline: 1.0, requestDeadline: 5.0,
                                      log: { _ in }) { _ in .versionResponse("served") }
        server.start()

        // Paced on the server's decisions so the test's 16-deep backlog never overflows.
        var rejected: [Int32] = []
        defer { rejected.forEach { close($0) } }
        for _ in 0..<50 {
            rejected.append(connectClient(path))
            #expect(decided.wait(timeout: .now() + 2) == .success)
        }

        let t0 = Date()
        let resp = try DaemonClient(socketPath: path).request(DaemonRequest(verb: .version), timeout: 2.0)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(resp.version == "served")
        #expect(elapsed < 1.0)
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
        let server = ConnectionServer(listenFD: listenFD, authorizer: fake,
                                      maxAcceptsPerEvent: 1,
                                      log: { _ in }) { _ in .versionResponse("served") }
        server.start()

        let resp = try DaemonClient(socketPath: path).request(DaemonRequest(verb: .version), timeout: 2.0)
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
        let server = ConnectionServer(listenFD: listenFD, authorizer: authorizer,
                                      log: { logged.append($0) }) { _ in
            handled.append(1)
            return .versionResponse("served")
        }
        server.start()

        let client = connectClient(path)
        defer { close(client) }
        let r = try sendAndRead(client)

        #expect(r.n == 0 || (r.n < 0 && r.err == ECONNRESET))
        Thread.sleep(forTimeInterval: 0.1)
        #expect(handled.all.isEmpty)
        #expect(logged.all.first?.contains("credentials unavailable: errno \(EINVAL)") == true)
    }

    // MARK: 5–6. Real kernel credentials

    @Test("Real getpeereid: owner = our uid is served")
    func realKernelAllowsOwner() throws {
        let path = uniquePath("real-allow")
        let listenFD = bindListener(path)
        defer { close(listenFD); unlink(path) }

        let server = ConnectionServer(listenFD: listenFD, authorizer: PeerAuthorizer(ownerUID: getuid()),
                                      log: { _ in }) { _ in .versionResponse("served") }
        server.start()

        let resp = try DaemonClient(socketPath: path).request(DaemonRequest(verb: .version))
        #expect(resp.version == "served")
    }

    @Test("Real getpeereid: owner = another uid rejects us", .enabled(if: getuid() != 0))
    func realKernelRejectsNonOwner() throws {
        let path = uniquePath("real-reject")
        let listenFD = bindListener(path)
        defer { close(listenFD); unlink(path) }

        let handled = Box<Int>()
        let logged = Box<String>()
        let server = ConnectionServer(listenFD: listenFD,
                                      authorizer: PeerAuthorizer(ownerUID: getuid() + 1),
                                      log: { logged.append($0) }) { _ in
            handled.append(1)
            return .versionResponse("served")
        }
        server.start()

        #expect(throws: (any Error).self) {
            try DaemonClient(socketPath: path).request(DaemonRequest(verb: .version))
        }
        Thread.sleep(forTimeInterval: 0.1)
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

        let decided = DispatchSemaphore(value: 0)
        let decisions = Box<PeerDecision>()
        let real = PeerAuthorizer(ownerUID: getuid())
        let recording = FakeAuthorizer { fd in
            let d = real.decide(fd: fd)
            decisions.append(d)
            decided.signal()
            return d
        }
        let server = ConnectionServer(listenFD: listenFD, authorizer: recording,
                                      log: { _ in }) { _ in .versionResponse("served") }
        server.start()

        #expect(decided.wait(timeout: .now() + 2) == .success)
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

    @Test("Through the server: a rejection flood logs at most 5 lines plus one timed summary")
    func logBoundThroughServer() throws {
        let path = uniquePath("flood")
        let listenFD = bindListener(path)
        defer { close(listenFD); unlink(path) }

        let logged = Box<String>()
        let decided = DispatchSemaphore(value: 0)
        let rejectAll = FakeAuthorizer.rejectAll()
        let counting = FakeAuthorizer { fd in decided.signal(); return rejectAll.decide(fd: fd) }
        let server = ConnectionServer(listenFD: listenFD, authorizer: counting,
                                      summaryDelay: 0.5,
                                      log: { logged.append($0) }) { _ in .versionResponse("served") }
        server.start()

        var fds: [Int32] = []
        defer { fds.forEach { close($0) } }
        for _ in 0..<100 {   // paced so the test's 16-deep backlog never overflows
            fds.append(connectClient(path))
            #expect(decided.wait(timeout: .now() + 2) == .success)
        }
        Thread.sleep(forTimeInterval: 0.7)   // past the one-shot summary

        // Exactly 5 rejection lines; every other line is a timed summary, and the
        // summaries account for all 95 suppressed. (Normally one summary; a slow
        // runner whose loop outlasts the delay may split the count across two.)
        let summaryPrefix = "ThermalForge daemon: "
        let summarySuffix = " further peer rejections suppressed"
        let summaries = logged.all.filter { $0.hasSuffix(summarySuffix) }
        let suppressedTotal = summaries.compactMap {
            Int($0.dropFirst(summaryPrefix.count).dropLast(summarySuffix.count))
        }.reduce(0, +)
        #expect(logged.all.count - summaries.count == 5)
        #expect(!summaries.isEmpty)
        #expect(suppressedTotal == 95)
    }
}
