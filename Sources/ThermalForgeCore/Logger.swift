// Runtime logs are best-effort: disk I/O must not block fan-control callers.
import Darwin
import Foundation
import os.log

public final class TFLogger {
    public static let shared = TFLogger(
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ThermalForge"),
        cleanupCaptures: { LogSessionRetention.cleanExpired() }
    )

    struct Policy {
        var retentionDays = 7
        var fileBytes = 5 * 1024 * 1024
        var totalBytes = 50 * 1024 * 1024
        var pendingEntries = 256
        var messageBytes = 8192
        var cleanupInterval: TimeInterval = 3600
        var retryInterval: TimeInterval = 60
    }
    struct Statistics {
        var pending = 0
        var dropped = 0
        var failures = 0
    }

    private let queue = DispatchQueue(label: "ThermalForge.runtime-log", qos: .utility)
    private let gate = NSLock()
    private var statistics = Statistics()
    private var days: Int
    private let policy: Policy
    private let store: RuntimeLogStore
    private let now: () -> Date
    private let cleanupCaptures: () -> Void
    private var timer: DispatchSourceTimer?
    private var retryAfter = Date.distantPast
    private let formatter = ISO8601DateFormatter()

    // Injectable location, clock and writer keep regression tests away from real logs.
    init(directory: URL, policy: Policy = Policy(), now: @escaping () -> Date = Date.init,
         append: @escaping (Data, URL) throws -> Void = RuntimeLogStore.append,
         cleanupCaptures: @escaping () -> Void = {}) {
        precondition(policy.fileBytes > 0 && policy.totalBytes >= policy.fileBytes)
        precondition(policy.pendingEntries > 0 && policy.messageBytes > 0 && policy.cleanupInterval > 0)
        self.policy = policy
        days = max(1, policy.retentionDays)
        self.now = now
        self.cleanupCaptures = cleanupCaptures
        store = RuntimeLogStore(directory: directory, policy: policy, append: append)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + policy.cleanupInterval, repeating: policy.cleanupInterval)
        timer.setEventHandler { [weak self] in self?.maintain() }
        self.timer = timer
        timer.resume()
        queue.async { [weak self] in self?.maintain() }
    }

    deinit { timer?.cancel() }

    public var retentionDays: Int {
        get { gate.lock(); defer { gate.unlock() }; return days }
        set { gate.lock(); days = max(1, newValue); gate.unlock() }
    }
    public var directory: URL { store.directory }
    public var path: URL { directory.appendingPathComponent(RuntimeLogStore.name(for: now())) }

    public func fan(_ message: String) { write("FAN", message) }
    public func profile(_ message: String) { write("PROFILE", message) }
    public func calibration(_ message: String) { write("CALIBRATION", message) }
    public func safety(_ message: String) { write("SAFETY", message) }
    public func daemon(_ message: String) { write("DAEMON", message) }
    public func error(_ message: String) { write("ERROR", message) }
    public func info(_ message: String) { write("INFO", message) }

    private func write(_ category: String, _ message: String) {
        gate.lock()
        guard statistics.pending < policy.pendingEntries else {
            statistics.dropped += 1
            gate.unlock()
            return
        }
        statistics.pending += 1
        gate.unlock()
        // Bound both the queue length and each captured message, including huge input.
        let prefix = Array(message.utf8.prefix(policy.messageBytes + 1))
        let text = String(decoding: prefix.prefix(policy.messageBytes), as: UTF8.self)
            + (prefix.count > policy.messageBytes ? " [truncated]" : "")
        let date = now()
        queue.async { [self] in
            defer { gate.lock(); statistics.pending -= 1; gate.unlock() }
            guard now() >= retryAfter else { dropped(); return }
            let data = Data("[\(formatter.string(from: date))] [\(category)] \(text)\n".utf8)
            guard data.count <= policy.fileBytes else { dropped(); return }
            do {
                try store.write(data, at: date, retentionDays: retentionDays)
            } catch RuntimeLogStore.Failure.busy {
                dropped() // Another process owns the same log directory; never wait on it.
            } catch { failed(error) }
        }
    }

    private func dropped() { gate.lock(); statistics.dropped += 1; gate.unlock() }
    private func failed(_ error: Error) {
        gate.lock(); statistics.failures += 1; statistics.dropped += 1; gate.unlock()
        retryAfter = now().addingTimeInterval(policy.retryInterval)
        os_log("Runtime log unavailable; retrying later: %{public}@", type: .error, String(describing: error))
    }
    private func maintain() {
        do { try store.maintain(at: now(), retentionDays: retentionDays) }
        catch RuntimeLogStore.Failure.busy { }
        catch { failed(error) }
        cleanupCaptures()
    }

    /// Remove only managed runtime logs, preserving unrelated files and the lock.
    public func clearAll() {
        queue.async { [self] in
            do { try store.clear() } catch { failed(error) }
        }
    }

    /// Bounded drain for orderly shutdown and tests; never used by control commands.
    @discardableResult public func flush(timeout: TimeInterval = 1) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + max(0, timeout)) == .success
    }
    var snapshot: Statistics { gate.lock(); defer { gate.unlock() }; return statistics }
}

final class RuntimeLogStore {
    enum Failure: Error { case busy, notRegularFile }
    let directory: URL
    private let policy: TFLogger.Policy
    private let writer: (Data, URL) throws -> Void
    private let fm = FileManager.default
    private struct File { let url: URL; let day: Date; let index: Int; let bytes: Int }
    /// Whether this process has pruned since it started. Touched only on the logger's queue.
    private var prunedSinceStart = false

    init(directory: URL, policy: TFLogger.Policy, append: @escaping (Data, URL) throws -> Void) {
        self.directory = directory; self.policy = policy; writer = append
    }
    private static func dateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }
    // Formatting through a shared, never-mutated formatter is thread-safe, and building a
    // formatter costs more than the write itself.
    private static let dayFormatter = dateFormatter()
    static func name(for date: Date) -> String { "thermalforge-\(dayFormatter.string(from: date)).log" }

    private func files() throws -> [File] {
        let formatter = Self.dayFormatter
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]).compactMap { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            let name = url.lastPathComponent
            if name == "thermalforge.log" { return File(url: url, day: .distantPast, index: 0, bytes: values.fileSize ?? 0) }
            guard name.hasPrefix("thermalforge-") else { return nil }
            let parts = name.dropFirst("thermalforge-".count).split(separator: ".", omittingEmptySubsequences: false)
            guard (parts.count == 2 || parts.count == 3), parts.last == "log",
                  let day = formatter.date(from: String(parts[0])), formatter.string(from: day) == parts[0] else { return nil }
            var index = Int.max // The current file sorts after its numbered archives.
            if parts.count == 3 {
                guard let n = Int(parts[1]), n > 0, String(n) == parts[1] else { return nil }
                index = n
            }
            return File(url: url, day: day, index: index, bytes: values.fileSize ?? 0)
        }.sorted { $0.day == $1.day ? $0.index < $1.index : $0.day < $1.day }
    }
    private func prune(at date: Date, days: Int, reserve: Int = 0) throws {
        let calendar = Calendar(identifier: .gregorian)
        let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: date)) ?? .distantPast
        var kept: [File] = []
        for file in try files() {
            if file.day < cutoff || file.bytes > policy.fileBytes { try fm.removeItem(at: file.url) }
            else { kept.append(file) }
        }
        var total = kept.reduce(0) { $0 + $1.bytes }
        for file in kept where total > policy.totalBytes - reserve {
            try fm.removeItem(at: file.url); total -= file.bytes
        }
    }
    private func locked(_ body: () throws -> Void) throws {
        let lock = directory.appendingPathComponent(".runtime-log.lock")
        let fd: Int32
        do { fd = try Self.openRegular(lock) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            // Only a missing directory costs a creation attempt, not every write.
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            fd = try Self.openRegular(lock)
        }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        defer { flock(fd, LOCK_UN) }
        try body()
    }
    func maintain(at date: Date, retentionDays: Int) throws {
        try locked {
            let size = Self.size(of: directory.appendingPathComponent(Self.name(for: date))) ?? 0
            try prune(at: date, days: retentionDays, reserve: max(0, policy.fileBytes - size))
            prunedSinceStart = true
        }
    }
    func clear() throws { try locked { for file in try files() { try fm.removeItem(at: file.url) } } }
    func write(_ data: Data, at date: Date, retentionDays: Int) throws {
        try locked {
            let current = directory.appendingPathComponent(Self.name(for: date))
            var size = Self.size(of: current)
            if let bytes = size, bytes + data.count > policy.fileBytes, try rotate(current) { size = nil }
            // The total only grows through the current file, which never exceeds fileBytes.
            // Pruning when a current file starts (rotation, a new day) or when this process
            // first writes leaves room for a full current file, so every append in between,
            // from any process, stays within totalBytes without rescanning the directory.
            if size == nil || !prunedSinceStart {
                try prune(at: date, days: retentionDays, reserve: max(0, policy.fileBytes - (size ?? 0)))
                prunedSinceStart = true
            }
            try writer(data, current)
        }
    }
    /// Archive the current file under the next free index for its day.
    private func rotate(_ current: URL) throws -> Bool {
        let entries = try files()
        guard let file = entries.first(where: { $0.url.lastPathComponent == current.lastPathComponent }) else { return false }
        let last = entries.filter { $0.day == file.day && $0.index != Int.max }.map(\.index).max() ?? 0
        guard last < Int.max - 1 else { throw Failure.notRegularFile }
        let archive = current.deletingPathExtension().appendingPathExtension("\(last + 1).log")
        try fm.moveItem(at: current, to: archive)
        return true
    }
    private static func size(of url: URL) -> Int? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? Int(info.st_size) : nil
    }
    private static func openRegular(_ url: URL) throws -> Int32 {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            Darwin.close(fd); throw Failure.notRegularFile
        }
        return fd
    }
    static func append(_ data: Data, to url: URL) throws {
        let fd = try openRegular(url)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }
}
