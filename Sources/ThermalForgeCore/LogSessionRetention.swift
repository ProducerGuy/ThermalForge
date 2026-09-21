import Darwin
import Foundation

/// Temporary captures carry an expiry from creation, even if the process crashes.
/// An advisory lock protects a live capture; the kernel releases it on process exit.
final class LogSessionRetention {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThermalForge/logs")
    }
    private let directory: URL
    private let permanent: Bool
    private var descriptor: Int32

    init(directory: URL, permanent: Bool, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = try Self.openLock(in: directory)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EWOULDBLOCK))
        }
        do {
            if permanent {
                try Data().write(to: directory.appendingPathComponent(".keep"), options: .atomic)
            } else {
                try Self.markExpiry(in: directory, now: now)
            }
        } catch { Darwin.close(fd); throw error }
        self.directory = directory
        self.permanent = permanent
        descriptor = fd
    }
    deinit { release() }
    func finish(at now: Date = Date()) throws {
        defer { release() }
        if !permanent { try Self.markExpiry(in: directory, now: now) }
    }
    func release() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }
    private static func markExpiry(in directory: URL, now: Date) throws {
        let expiry = ISO8601DateFormatter().string(from: now.addingTimeInterval(24 * 3600))
        try expiry.write(to: directory.appendingPathComponent(".expires"), atomically: true, encoding: .utf8)
    }
    private static func openLock(in directory: URL) throws -> Int32 {
        let fd = Darwin.open(directory.appendingPathComponent(".active.lock").path,
                             O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        return fd
    }
    static func cleanExpired(in root: URL = defaultDirectory, now: Date = Date()) {
        let fm = FileManager.default
        guard let directories = try? fm.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for directory in directories {
            let name = directory.lastPathComponent
            guard name.hasPrefix("thermalforge_log_"),
                  let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  !fm.fileExists(atPath: directory.appendingPathComponent(".keep").path) else { continue }
            let marker = directory.appendingPathComponent(".expires")
            guard let values = try? marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 129) <= 128,
                  let fd = try? openLock(in: directory) else { continue }
            defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            // Read expiry under the lease: completion may just have extended it.
            guard !fm.fileExists(atPath: directory.appendingPathComponent(".keep").path),
                  let text = try? String(contentsOf: marker, encoding: .utf8),
                  let expiry = ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  expiry <= now else { continue }
            // Unmarked legacy sessions may be deliberate exports: never infer expiry.
            try? fm.removeItem(at: directory)
        }
    }
}

/// A temporary capture stops cleanly at its CSV budget; explicit exports opt out.
final class CaptureLogWriter {
    private let limit: Int?
    private(set) var bytesWritten = 0
    init(limit: Int? = 100 * 1024 * 1024) { self.limit = limit }
    func write(_ data: Data, to handle: FileHandle) throws {
        if let limit, data.count > limit - bytesWritten {
            throw NSError(domain: "ThermalLogger", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Temporary recording reached its size limit (default 100 MiB). Use --output or --no-expire for larger recordings."])
        }
        try handle.write(contentsOf: data)
        bytesWritten += data.count
    }
}
