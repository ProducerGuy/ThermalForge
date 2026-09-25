import Darwin
import Foundation
import Testing
@testable import ThermalForgeCore

@Suite("Local M4 handoff repair — no hardware writes")
struct LocalHandoffRepairTests {
    @Test("already manual fans cause no Ftst write, retry or sleep")
    func alreadyManual() throws {
        var writes = 0
        var sleeps = 0
        try FanHandoff.acquire(
            indices: [0, 1], hasFtst: true, modeKey: { "F\($0)Md" },
            readMode: { _ in 1 }, write: { _, _ in writes += 1; return true },
            sleep: { _ in sleeps += 1 }
        )
        #expect(writes == 0)
        #expect(sleeps == 0)
    }

    @Test("cold M4 acquisition can finish after twelve seconds, then fast-path")
    func slowAcquisition() throws {
        var clock = 0.0
        var modes: [UInt8] = [0, 0]
        var unlockWrites = 0
        func acquire() throws {
            try FanHandoff.acquire(
                indices: [0, 1], hasFtst: true, modeKey: { "F\($0)Md" },
                readMode: { modes[$0] },
                write: { key, _ in
                    if key == SMCFanKey.forceTest { unlockWrites += 1; return true }
                    guard clock >= 12 else { return false }
                    modes[key == "F0Md" ? 0 : 1] = 1
                    return true
                },
                sleep: { clock += $0 }, now: { clock }
            )
        }
        try acquire()
        #expect(clock >= 12 && clock < 12.2)
        #expect(modes == [1, 1])
        let firstClock = clock
        try acquire()
        #expect(clock == firstClock)
        #expect(unlockWrites == 1)
        // Wake/system handback must be detected from real mode reads, not a cache.
        modes = [0, 0]
        try acquire()
        #expect(unlockWrites == 2)
    }

    @Test("failed mode acquisition is still bounded and reported")
    func acquisitionFailure() {
        var clock = 0.0
        #expect(throws: (any Error).self) {
            try FanHandoff.acquire(
                indices: [0, 1], hasFtst: true, modeKey: { "F\($0)Md" },
                readMode: { _ in 0 }, write: { key, _ in key == SMCFanKey.forceTest },
                sleep: { clock += $0 }, now: { clock }
            )
        }
        #expect(clock >= 20 && clock < 20.2)
    }

    @Test("only the fan requiring acquisition gets a mode write")
    func partialManual() throws {
        var keys: [String] = []
        try FanHandoff.acquire(
            indices: [0, 1], hasFtst: false, modeKey: { "F\($0)Md" },
            readMode: { $0 == 0 ? 1 : 0 },
            write: { key, _ in keys.append(key); return true }
        )
        #expect(keys == ["F1Md"])
    }

    @Test("hardware budget covers shared acquisition deadline, liveness stays two seconds")
    func timeoutPolicy() {
        for verb: DaemonRequest.Verb in [.max, .set, .setfan, .auto] {
            #expect(DaemonRequestPolicy.timeout(for: verb) > FanHandoff.acquisitionSeconds)
            #expect(DaemonRequestPolicy.needsSMCLock(verb))
        }
        for verb: DaemonRequest.Verb in [.heartbeat, .state, .version] {
            #expect(DaemonRequestPolicy.timeout(for: verb) == 2)
            #expect(!DaemonRequestPolicy.needsSMCLock(verb))
        }
        #expect(DaemonRequestPolicy.needsSMCLock(.status))
    }

    @Test("read timeout differs from peer EOF")
    func timeoutVersusEOF() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fds[0], SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #expect(throws: DaemonProtocol.FrameError.timeout) {
            _ = try DaemonProtocol.readFrame(fds[0], max: 4096)
        }
        shutdown(fds[1], SHUT_WR)
        #expect(throws: DaemonProtocol.FrameError.closed) {
            _ = try DaemonProtocol.readFrame(fds[0], max: 4096)
        }
    }

    private func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) {
                _ = strlcpy($0, path, 104)
            }
        }
        return addr
    }

    private func listener(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = address(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(rc == 0)
        #expect(listen(fd, 8) == 0)
        return fd
    }

    private func client(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = address(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(rc == 0)
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private func send(_ fd: Int32, _ verb: DaemonRequest.Verb) throws {
        try DaemonProtocol.writeFrame(fd, DaemonProtocol.encodeFrame(
            DaemonRequest(verb: verb, rpm: verb == .set ? 1350 : nil),
            max: DaemonProtocol.maxRequestBytes
        ))
    }

    @Test("slow hardware reply survives body deadline and does not block liveness")
    func slowReplyAndLiveness() throws {
        let path = "/tmp/tf-local-\(UUID().uuidString).sock"
        let fd = listener(path)
        defer { close(fd); unlink(path) }
        let lock = NSLock()
        let started = DispatchSemaphore(value: 0)
        let server = ConnectionServer(listenFD: fd, headerDeadline: 1, requestDeadline: 0.1) { data in
            let req = try! DaemonProtocol.decode(DaemonRequest.self, from: data)
            return DaemonRequestPolicy.perform(req.verb, lock: lock) {
                if req.verb == .set {
                    started.signal()
                    Thread.sleep(forTimeInterval: 0.5)
                }
                return .ok()
            }
        }
        server.start()
        let slow = client(path)
        defer { close(slow) }
        try send(slow, .set)
        #expect(started.wait(timeout: .now() + 1) == .success)
        for verb: DaemonRequest.Verb in [.state, .heartbeat, .version] {
            let fast = client(path)
            defer { close(fast) }
            let begin = ProcessInfo.processInfo.systemUptime
            try send(fast, verb)
            _ = try DaemonProtocol.readFrame(fast, max: 65536)
            #expect(ProcessInfo.processInfo.systemUptime - begin < 0.2)
        }
        let data = try DaemonProtocol.readFrame(slow, max: 65536)
        #expect(try DaemonProtocol.decode(DaemonResponse.self, from: data).ok)
    }

    @Test("timed-out client cannot SIGPIPE the server; subsequent requests work")
    func abandonedReply() throws {
        let path = "/tmp/tf-local-\(UUID().uuidString).sock"
        let fd = listener(path)
        defer { close(fd); unlink(path) }
        let started = DispatchSemaphore(value: 0)
        let server = ConnectionServer(listenFD: fd) { _ in
            started.signal()
            Thread.sleep(forTimeInterval: 0.1)
            return .ok()
        }
        server.start()
        let abandoned = client(path)
        try send(abandoned, .version)
        #expect(started.wait(timeout: .now() + 1) == .success)
        close(abandoned)
        Thread.sleep(forTimeInterval: 0.2)
        let next = client(path)
        defer { close(next) }
        try send(next, .version)
        let data = try DaemonProtocol.readFrame(next, max: 65536)
        #expect(try DaemonProtocol.decode(DaemonResponse.self, from: data).ok)
    }
}
