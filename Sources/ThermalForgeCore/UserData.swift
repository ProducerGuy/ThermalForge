//
//  UserData.swift
//  ThermalForge
//
//  Where a user's ThermalForge data lives (calibration, recordings) and how it's
//  written. The menu bar app runs as the user and reads from the user's home, so a
//  command run with sudo must save there too, owned by that user, or the app never
//  sees it: under sudo, the home folder Foundation reports is root's.
//
//  Running as root in a folder the user controls, every write goes through open
//  descriptors: below the base folder nothing is followed through a symlink, files
//  are created exclusively, and anything created is handed to the user with fchown
//  on its descriptor. So a link planted in the user's home can't redirect a root
//  write or chown somewhere else.
//

import Darwin
import Foundation

/// Whose data this process reads and writes, and where.
public struct UserDataLocation: Equatable {
    public enum Kind: Equatable {
        /// Not root: the user's own home, as always.
        case currentUser
        /// Root under sudo: the home of the user who ran sudo, and what's created
        /// there is handed to them.
        case sudoUser
        /// Root with no sudo user (a root shell, or SUDO_UID unusable): root's own
        /// home, root-owned. The app, running as a user, never reads it.
        case root
    }

    public struct Owner: Equatable {
        public let uid: uid_t
        public let gid: gid_t
    }

    public let kind: Kind
    public let home: URL
    /// Set for `.sudoUser`: everything created is given to this user.
    public let owner: Owner?

    /// ~/Library/Application Support/ThermalForge, as path components below `home`.
    public static let appSupportComponents = ["Library", "Application Support", "ThermalForge"]

    public var appSupport: URL {
        Self.appSupportComponents.reduce(home) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    /// Decide from the effective user and the environment. Under sudo the user is
    /// found the same way install finds the owner: SUDO_UID, never 0, then that
    /// account's home folder and primary group.
    static func resolve(euid: uid_t, environment: [String: String],
                        account: (uid_t) -> (gid: gid_t, home: String)?,
                        currentHome: URL) -> UserDataLocation {
        guard euid == 0 else {
            return UserDataLocation(kind: .currentUser, home: currentHome, owner: nil)
        }
        if let text = environment["SUDO_UID"], let uid = uid_t(text), uid != 0,
           let account = account(uid) {
            return UserDataLocation(kind: .sudoUser,
                                    home: URL(fileURLWithPath: account.home, isDirectory: true),
                                    owner: Owner(uid: uid, gid: account.gid))
        }
        return UserDataLocation(kind: .root, home: currentHome, owner: nil)
    }

    /// This process's location, decided once.
    public static let current = resolve(
        euid: geteuid(),
        environment: ProcessInfo.processInfo.environment,
        account: systemAccount,
        currentHome: FileManager.default.homeDirectoryForCurrentUser)

    static func systemAccount(_ uid: uid_t) -> (gid: gid_t, home: String)? {
        guard let entry = getpwuid(uid), let dir = entry.pointee.pw_dir else { return nil }
        let home = String(cString: dir)
        return home.isEmpty ? nil : (entry.pointee.pw_gid, home)
    }

    /// File access for this location.
    public var files: UserFiles { UserFiles(owner: owner) }
}

/// File operations below a trusted base folder (a home folder, or a folder the user
/// named). The base is opened normally; every component below it is opened without
/// following symlinks, missing folders are created (0755), files are created
/// exclusively (0644), and with an owner set everything created is chowned to them.
public struct UserFiles {
    public let owner: UserDataLocation.Owner?

    public init(owner: UserDataLocation.Owner?) {
        self.owner = owner
    }

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let action: String
        public let path: String
        public let errno: Int32

        public var description: String {
            let reason = errno == ELOOP
                ? "it's a symbolic link, which is never followed"
                : "\(String(cString: strerror(errno))) (errno \(errno))"
            return "couldn't \(action) \(path): \(reason)"
        }
    }

    /// Make sure base/components exists, creating what's missing.
    public func ensureDirectory(base: URL, _ components: [String]) throws {
        if let fd = try openDirectory(base: base, components, create: true) { close(fd) }
    }

    /// Create a new file and return a handle for writing. Fails if anything is
    /// already at that name.
    public func createFile(base: URL, _ components: [String], name: String) throws -> FileHandle {
        let path = Self.path(base, components, name)
        guard let dir = try openDirectory(base: base, components, create: true) else {
            throw Failure(action: "create", path: path, errno: ENOENT)
        }
        defer { close(dir) }
        let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Failure(action: "create", path: path, errno: errno) }
        if let owner, fchown(fd, owner.uid, owner.gid) != 0 {
            let err = errno
            close(fd)
            unlinkat(dir, name, 0)
            throw Failure(action: "hand over", path: path, errno: err)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Write `data` to base/components/name in one step: a new file beside it,
    /// then a rename over the old one, so a reader sees the old or the new
    /// contents, never a partial file. The rename replaces a symlink at that
    /// name itself; it never writes through it.
    public func writeFile(base: URL, _ components: [String], name: String, data: Data) throws {
        let path = Self.path(base, components, name)
        guard let dir = try openDirectory(base: base, components, create: true) else {
            throw Failure(action: "write", path: path, errno: ENOENT)
        }
        defer { close(dir) }
        let temp = ".\(name).\(UUID().uuidString).tmp"
        let fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Failure(action: "write", path: path, errno: errno) }
        var failure: Int32 = 0
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += n
            }
        }
        if failure == 0, let owner, fchown(fd, owner.uid, owner.gid) != 0 { failure = errno }
        close(fd)
        if failure == 0, renameat(dir, temp, dir, name) != 0 { failure = errno }
        if failure != 0 {
            unlinkat(dir, temp, 0)
            throw Failure(action: "write", path: path, errno: failure)
        }
    }

    /// The contents of base/components/name, or nil when it (or a folder on the
    /// way) doesn't exist. Creates nothing. A symlink or non-regular file throws.
    public func readFile(base: URL, _ components: [String], name: String) throws -> Data? {
        let path = Self.path(base, components, name)
        guard let dir = try openDirectory(base: base, components, create: false) else { return nil }
        defer { close(dir) }
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw Failure(action: "read", path: path, errno: errno)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure(action: "read", path: path, errno: errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw Failure(action: "read", path: path, errno: EFTYPE)
        }
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw Failure(action: "read", path: path, errno: EIO)
        }
    }

    /// Remove base/components/name. A symlink there is removed itself, never what
    /// it points to. Returns whether anything was removed.
    @discardableResult
    public func removeFile(base: URL, _ components: [String], name: String) throws -> Bool {
        let path = Self.path(base, components, name)
        guard let dir = try openDirectory(base: base, components, create: false) else { return false }
        defer { close(dir) }
        guard unlinkat(dir, name, 0) == 0 else {
            if errno == ENOENT { return false }
            throw Failure(action: "remove", path: path, errno: errno)
        }
        return true
    }

    // MARK: - Internals

    /// Open base, then each component without following symlinks. With `create`,
    /// missing folders are made and handed to the owner; without it, a missing one
    /// returns nil. The caller closes the returned descriptor.
    private func openDirectory(base: URL, _ components: [String], create: Bool) throws -> Int32? {
        var fd = open(base.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT && !create { return nil }
            throw Failure(action: "open", path: base.path, errno: errno)
        }
        var path = base.path
        for name in components {
            path += "/" + name
            var created = false
            if create {
                if mkdirat(fd, name, 0o755) == 0 {
                    created = true
                } else if errno != EEXIST {
                    let err = errno
                    close(fd)
                    throw Failure(action: "create", path: path, errno: err)
                }
            }
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            var err = errno
            if next < 0 && err == ENOTDIR {
                // O_DIRECTORY can report a symlink as "not a directory"; say which.
                var info = stat()
                if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && (info.st_mode & S_IFMT) == S_IFLNK {
                    err = ELOOP
                }
            }
            close(fd)
            guard next >= 0 else {
                if err == ENOENT && !create { return nil }
                throw Failure(action: "open", path: path, errno: err)
            }
            fd = next
            if created, let owner, fchown(fd, owner.uid, owner.gid) != 0 {
                let err = errno
                close(fd)
                throw Failure(action: "hand over", path: path, errno: err)
            }
        }
        return fd
    }

    private static func path(_ base: URL, _ components: [String], _ name: String) -> String {
        ([base.path] + components + [name]).joined(separator: "/")
    }
}
