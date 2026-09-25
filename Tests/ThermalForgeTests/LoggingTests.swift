import Darwin
import Foundation
import Testing
@testable import ThermalForgeCore

@Suite(.serialized)
struct LoggingTests {
    final class Clock {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_790_000_000)
        func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thermalforge-logging-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func logs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "log" }
    }
    private func policy() -> TFLogger.Policy {
        var p = TFLogger.Policy(); p.fileBytes = 512; p.totalBytes = 1536; return p
    }

    @Test("Rotation preserves recent records and bounds individual and total files")
    func rotation() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let logger = TFLogger(directory: root, policy: policy())
        for n in 0..<80 { logger.info("record-\(n) " + String(repeating: "x", count: 80)) }
        #expect(logger.flush())
        let files = try logs(in: root)
        let data = try files.map { try Data(contentsOf: $0) }
        #expect(files.count > 1)
        #expect(data.allSatisfy { $0.count <= 512 })
        #expect(data.reduce(0) { $0 + $1.count } <= 1536)
        #expect(try String(contentsOf: logger.path, encoding: .utf8).contains("record-79"))
    }

    @Test("Maintenance removes expired files during an idle long-running process")
    func idleExpiry() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(); var p = policy(); p.cleanupInterval = 0.03
        let logger = TFLogger(directory: root, policy: p, now: clock.read)
        logger.info("before midnight"); #expect(logger.flush())
        let old = logger.path
        clock.advance(8 * 86400)
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: old.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: old.path))
        logger.info("after rollover"); #expect(logger.flush())
        #expect(logger.path != old)
        #expect(try String(contentsOf: logger.path, encoding: .utf8).contains("after rollover"))
    }

    @Test("Seven calendar days are retained and unrelated paths survive cleanup")
    func retentionBoundary() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(); let today = clock.read()
        let sixDays = root.appendingPathComponent(RuntimeLogStore.name(for: today - 6 * 86400))
        let sevenDays = root.appendingPathComponent(RuntimeLogStore.name(for: today - 7 * 86400))
        for path in [sixDays, sevenDays, root.appendingPathComponent("notes.log"), root.appendingPathComponent("thermalforge-invalid.log")] {
            try Data("preserve".utf8).write(to: path)
        }
        let logger = TFLogger(directory: root, policy: policy(), now: clock.read)
        #expect(logger.flush())
        #expect(FileManager.default.fileExists(atPath: sixDays.path))
        #expect(!FileManager.default.fileExists(atPath: sevenDays.path))
        logger.clearAll(); #expect(logger.flush())
        #expect(!FileManager.default.fileExists(atPath: sixDays.path))
        #expect(try String(contentsOf: root.appendingPathComponent("notes.log"), encoding: .utf8) == "preserve")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("thermalforge-invalid.log").path))
    }

    @Test("A blocked disk writer cannot block callers or grow the pending queue indefinitely")
    func boundedQueue() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var p = policy(); p.pendingEntries = 4
        let logger = TFLogger(directory: root, policy: p, append: { data, url in
            started.signal(); _ = release.wait(timeout: .now() + 5)
            try RuntimeLogStore.append(data, to: url)
        })
        defer { for _ in 0..<4 { release.signal() }; _ = logger.flush() }
        logger.info("blocked")
        #expect(started.wait(timeout: .now() + 1) == .success)
        let before = Date()
        for _ in 0..<1000 { logger.info("overload") }
        #expect(Date().timeIntervalSince(before) < 0.5)
        #expect(logger.snapshot.pending == 4)
        #expect(logger.snapshot.dropped == 997)
        #expect(!logger.flush(timeout: 0.01))
    }

    @Test("Write failures back off without throwing into callers and recover later")
    func failureRecovery() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(); var attempts = 0
        let logger = TFLogger(directory: root, policy: policy(), now: clock.read, append: { data, url in
            attempts += 1
            if attempts == 1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
            try RuntimeLogStore.append(data, to: url)
        })
        logger.error("disk full"); #expect(logger.flush())
        logger.info("during backoff"); #expect(logger.flush())
        #expect(attempts == 1)
        #expect(logger.snapshot.failures == 1)
        clock.advance(61)
        logger.info("recovered"); #expect(logger.flush())
        #expect(attempts == 2)
        #expect(try String(contentsOf: logger.path, encoding: .utf8).contains("recovered"))
    }

    @Test("Invalid destinations and linked log files leave unrelated data untouched")
    func unsafeDestinations() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let victim = root.appendingPathComponent("important.txt")
        try Data("untouched".utf8).write(to: victim)
        let invalid = TFLogger(directory: victim)
        invalid.info("cannot create directory"); #expect(invalid.flush())
        #expect(invalid.snapshot.failures > 0)
        let destination = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let linked = destination.appendingPathComponent(RuntimeLogStore.name(for: Date()))
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: victim)
        let logger = TFLogger(directory: destination)
        logger.info("cannot follow symlink"); #expect(logger.flush())
        #expect(logger.snapshot.failures == 1)
        logger.clearAll(); #expect(logger.flush())
        #expect(try String(contentsOf: victim, encoding: .utf8) == "untouched")
    }

    @Test("Concurrent loggers coordinate rotation in the same directory")
    func concurrentWriters() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let a = TFLogger(directory: root, policy: policy()), b = TFLogger(directory: root, policy: policy())
        DispatchQueue.concurrentPerform(iterations: 100) { n in
            (n % 2 == 0 ? a : b).info("record-\(n) " + String(repeating: "x", count: 100))
        }
        #expect(a.flush()); #expect(b.flush())
        let data = try logs(in: root).map { try Data(contentsOf: $0) }
        #expect(!data.isEmpty)
        #expect(data.allSatisfy { $0.count <= 512 })
        #expect(data.reduce(0) { $0 + $1.count } <= 1536)
        #expect(a.snapshot.failures == 0 && b.snapshot.failures == 0)
    }

    @Test("A directory filled by an earlier version stays bounded as the current file grows")
    func boundedAfterUpgrade() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        // Earlier versions pruned only for the next line, so other files could fill nearly
        // the whole budget. Writes that only stat the current file must still stay bounded.
        let today = RuntimeLogStore.name(for: Date())
        let stem = String(today.dropLast(".log".count))
        for n in 1...3 { try Data(count: 400).write(to: root.appendingPathComponent("\(stem).\(n).log")) }
        try Data(count: 100).write(to: root.appendingPathComponent(today))
        let logger = TFLogger(directory: root, policy: policy())
        for n in 0..<40 {
            logger.info("record-\(n) " + String(repeating: "x", count: 60)); #expect(logger.flush())
            let data = try logs(in: root).map { try Data(contentsOf: $0) }
            #expect(data.allSatisfy { $0.count <= 512 })
            #expect(data.reduce(0) { $0 + $1.count } <= 1536)
        }
        #expect(try String(contentsOf: logger.path, encoding: .utf8).contains("record-39"))
        #expect(logger.snapshot.failures == 0)
    }

    @Test("Huge messages are bounded without producing invalid UTF-8")
    func boundedMessage() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var p = policy(); p.messageBytes = 31
        let logger = TFLogger(directory: root, policy: p)
        logger.info(String(repeating: "风扇", count: 100_000)); #expect(logger.flush())
        let data = try Data(contentsOf: logger.path)
        #expect(data.count < 150)
        #expect(String(data: data, encoding: .utf8)?.contains("[truncated]") == true)
    }

    @Test("Expired live captures are protected and abandoned captures are reclaimable")
    func captureLease() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let day = Date(); let directory = root.appendingPathComponent("thermalforge_log_test")
        let lease = try LogSessionRetention(directory: directory, permanent: false, now: day)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".expires").path))
        LogSessionRetention.cleanExpired(in: root, now: day + 2 * 86400)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        lease.release() // Models the kernel releasing the lock after abrupt termination.
        LogSessionRetention.cleanExpired(in: root, now: day + 2 * 86400)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Completion extends retention for a capture longer than 24 hours")
    func completedCapture() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(); let directory = root.appendingPathComponent("thermalforge_log_test")
        let lease = try LogSessionRetention(directory: directory, permanent: false, now: start)
        try lease.finish(at: start + 2 * 86400)
        LogSessionRetention.cleanExpired(in: root, now: start + 2.5 * 86400)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        LogSessionRetention.cleanExpired(in: root, now: start + 4 * 86400)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("Permanent, unmarked, malformed and unrelated captures survive cleanup")
    func preserveExports() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(); let permanent = root.appendingPathComponent("thermalforge_log_permanent")
        let lease = try LogSessionRetention(directory: permanent, permanent: true, now: start)
        try lease.finish(at: start)
        for name in ["thermalforge_log_unmarked", "unrelated", "thermalforge_log_malformed"] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if name != "thermalforge_log_unmarked" {
                try (name == "unrelated" ? "2000-01-01T00:00:00Z" : "invalid").write(
                    to: directory.appendingPathComponent(".expires"), atomically: true, encoding: .utf8)
            }
        }
        let link = root.appendingPathComponent("thermalforge_log_symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: permanent)
        LogSessionRetention.cleanExpired(in: root, now: start + 30 * 86400)
        for name in ["thermalforge_log_permanent", "thermalforge_log_unmarked", "unrelated", "thermalforge_log_malformed", "thermalforge_log_symlink"] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
    }

    @Test("CSV size limits stop before an oversized write; permanent exports opt out")
    func captureSize() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("capture.csv")
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        let writer = CaptureLogWriter(limit: 10)
        try writer.write(Data("12345678".utf8), to: handle)
        #expect(throws: (any Error).self) { try writer.write(Data("901".utf8), to: handle) }
        #expect(try Data(contentsOf: file).count == 8)
        try CaptureLogWriter(limit: nil).write(Data(repeating: 120, count: 100), to: handle)
        #expect(try Data(contentsOf: file).count == 108)
    }
}
