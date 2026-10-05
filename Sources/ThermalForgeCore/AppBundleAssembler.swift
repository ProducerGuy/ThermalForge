//
//  AppBundleAssembler.swift
//  ThermalForge
//
//  The single ThermalForge.app assembler, used by `build-app` (setup.sh and the
//  Homebrew formula) and by `install`'s build route. It runs as root, so it copies
//  only the exact regular files it checked, and replaces an existing bundle only
//  once the new one is complete, in one atomic step (AtomicReplace). Under sudo,
//  every item of the staged bundle is handed to the user who ran sudo before the
//  swap (BundleOwnership), so the app can be trashed or replaced without a password.
//

import Darwin
import Foundation

public enum AppBundleAssembler {

    /// Build `dest` from an app binary and an icon. The bundle is assembled next to
    /// `dest` first and swapped in atomically only after that succeeds, so a bad
    /// source leaves the installed app as it was and there's never a moment with
    /// no app. With an `owner` (root under sudo), every item is handed to them
    /// before the swap. Returns a warning if the swapped-out old bundle couldn't be
    /// removed.
    @discardableResult
    public static func assemble(binary: String, icon: String, dest: String,
                                owner: UserDataLocation.Owner? = UserDataLocation.current.owner) throws -> String? {
        let fm = FileManager.default
        let staging = AtomicReplace.stagingPath(for: dest)
        try? fm.removeItem(atPath: staging)   // a leftover from an interrupted run
        do {
            let contents = "\(staging)/Contents"
            try fm.createDirectory(atPath: "\(contents)/MacOS", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: "\(contents)/Resources", withIntermediateDirectories: true)
            try SafeFileCopy.copyRegularFile(from: binary, to: "\(contents)/MacOS/ThermalForgeApp",
                                             requireExecutable: true)
            try SafeFileCopy.copyRegularFile(from: icon, to: "\(contents)/Resources/AppIcon.icns")
            try infoPlist().write(toFile: "\(contents)/Info.plist", atomically: true, encoding: .utf8)
            if let owner { try BundleOwnership.handOver(staging, to: owner) }
        } catch {
            try? fm.removeItem(atPath: staging)
            throw error
        }

        return try AtomicReplace.replace(dest, with: staging)
    }

    static func infoPlist() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key>
            <string>ThermalForge</string>
            <key>CFBundleDisplayName</key>
            <string>ThermalForge</string>
            <key>CFBundleIdentifier</key>
            <string>com.thermalforge.app</string>
            <key>CFBundleVersion</key>
            <string>\(ThermalForgeVersion.current)</string>
            <key>CFBundleShortVersionString</key>
            <string>\(ThermalForgeVersion.current)</string>
            <key>CFBundleExecutable</key>
            <string>ThermalForgeApp</string>
            <key>CFBundleIconFile</key>
            <string>AppIcon</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>LSMinimumSystemVersion</key>
            <string>\(ThermalForgeVersion.minimumMacOS)</string>
            <key>LSUIElement</key>
            <true/>
            <key>NSHighResolutionCapable</key>
            <true/>
        </dict>
        </plist>
        """
    }
}

/// Hand every item of a staged bundle to one user: the bundle folder, every folder
/// and file inside, and any symlink itself. It works through descriptors and never
/// follows a symlink, so nothing planted in the staging folder can redirect a root
/// chown elsewhere. Anything other than a folder, regular file or symlink fails it.
public enum BundleOwnership {

    public static func handOver(_ path: String, to owner: UserDataLocation.Owner) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw UserFiles.Failure(action: "hand over", path: path, errno: errno) }
        defer { close(fd) }
        try handOver(directory: fd, path: path, to: owner)
    }

    private static func handOver(directory fd: Int32, path: String, to owner: UserDataLocation.Owner) throws {
        guard fchown(fd, owner.uid, owner.gid) == 0 else {
            throw UserFiles.Failure(action: "hand over", path: path, errno: errno)
        }
        for name in try entries(of: fd, path: path) {
            let itemPath = path + "/" + name
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw UserFiles.Failure(action: "hand over", path: itemPath, errno: errno)
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else {
                    throw UserFiles.Failure(action: "hand over", path: itemPath, errno: errno)
                }
                defer { close(child) }
                try handOver(directory: child, path: itemPath, to: owner)
            case S_IFREG:
                let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard file >= 0 else {
                    throw UserFiles.Failure(action: "hand over", path: itemPath, errno: errno)
                }
                defer { close(file) }
                guard fchown(file, owner.uid, owner.gid) == 0 else {
                    throw UserFiles.Failure(action: "hand over", path: itemPath, errno: errno)
                }
            case S_IFLNK:
                // The link itself, never what it points to.
                guard fchownat(fd, name, owner.uid, owner.gid, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw UserFiles.Failure(action: "hand over", path: itemPath, errno: errno)
                }
            default:
                throw UserFiles.Failure(action: "hand over", path: itemPath, errno: EFTYPE)
            }
        }
    }

    /// The names in an open folder, read through a duplicate descriptor.
    private static func entries(of fd: Int32, path: String) throws -> [String] {
        let listing = dup(fd)
        guard listing >= 0, let dir = fdopendir(listing) else {
            let err = errno
            if listing >= 0 { close(listing) }
            throw UserFiles.Failure(action: "hand over", path: path, errno: err)
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
}

/// Copy one regular file so that what gets written is exactly the file that was
/// checked. The source is opened once, without following a symlink; the checks run
/// on that open handle, and the bytes, permissions and owner come from it too. A
/// swap of the path after the check can't change what's copied.
public enum SafeFileCopy {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case cannotOpen(path: String, errno: Int32)
        case notRegularFile(path: String)
        case notExecutable(path: String)
        case cannotCreate(path: String, errno: Int32)
        case ioFailed(path: String, errno: Int32)

        public var description: String {
            switch self {
            case .cannotOpen(let path, let err):
                return "couldn't open \(path): \(Self.reason(err))"
            case .notRegularFile(let path):
                return "\(path) isn't a regular file (a symlink, folder or other special file is never installed)"
            case .notExecutable(let path):
                return "\(path) isn't executable"
            case .cannotCreate(let path, let err):
                return "couldn't create \(path): \(Self.reason(err))"
            case .ioFailed(let path, let err):
                return "couldn't write \(path): \(Self.reason(err))"
            }
        }

        private static func reason(_ err: Int32) -> String {
            "\(String(cString: strerror(err))) (errno \(err))"
        }
    }

    public static func copyRegularFile(from source: String, to dest: String,
                                       requireExecutable: Bool = false) throws {
        // O_NOFOLLOW: a symlink at `source` fails here instead of being followed.
        // O_NONBLOCK: a FIFO planted at `source` can't stall the open; it fails the
        // regular-file check below instead.
        let input = open(source, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else {
            let err = errno
            throw err == ELOOP ? Failure.notRegularFile(path: source) : Failure.cannotOpen(path: source, errno: err)
        }
        defer { close(input) }

        var info = stat()
        guard fstat(input, &info) == 0 else { throw Failure.cannotOpen(path: source, errno: errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.notRegularFile(path: source) }
        if requireExecutable && (info.st_mode & 0o111) == 0 { throw Failure.notExecutable(path: source) }

        // O_EXCL: never write through or over anything already at `dest`.
        let output = open(dest, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Failure.cannotCreate(path: dest, errno: errno) }
        var finished = false
        defer {
            close(output)
            if !finished { unlink(dest) }
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                throw Failure.ioFailed(path: dest, errno: errno)
            }
            var written = 0
            while written < n {
                let w = buffer.withUnsafeBytes { write(output, $0.baseAddress! + written, n - written) }
                if w < 0 {
                    if errno == EINTR { continue }
                    throw Failure.ioFailed(path: dest, errno: errno)
                }
                written += w
            }
        }

        // Owner first (as root only; a non-root copy can't change it), then mode:
        // the same owner and permissions the previous copy kept, minus setuid/setgid.
        if geteuid() == 0 && fchown(output, info.st_uid, info.st_gid) != 0 {
            throw Failure.ioFailed(path: dest, errno: errno)
        }
        guard fchmod(output, info.st_mode & 0o777) == 0 else {
            throw Failure.ioFailed(path: dest, errno: errno)
        }
        finished = true
    }
}

/// Put a fully built bundle in place in one step. When something already sits at
/// the destination, the two are exchanged atomically (renamex_np with RENAME_SWAP),
/// so the path always holds either the old app or the new one, never nothing; the
/// old one, now at the staging path, is removed afterward. If the exchange fails,
/// the installed app is untouched and the staged copy is discarded.
public enum AtomicReplace {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case replaceFailed(path: String, errno: Int32)

        public var description: String {
            switch self {
            case .replaceFailed(let path, let err):
                return "couldn't replace \(path): \(String(cString: strerror(err))) (errno \(err)). "
                    + "The existing app is untouched."
            }
        }
    }

    /// Where a replacement for `dest` is built: beside it, so the swap stays on
    /// one volume.
    public static func stagingPath(for dest: String) -> String {
        dest + ".staged"
    }

    /// Returns a warning when the swapped-out old bundle couldn't be removed; the
    /// new app is in place either way.
    @discardableResult
    public static func replace(_ dest: String, with staged: String) throws -> String? {
        let fm = FileManager.default
        var info = stat()
        let destExists = lstat(dest, &info) == 0
        // Swap with what's there, or (nothing there) a rename that refuses to
        // overwrite anything that appears meanwhile.
        let flags = UInt32(destExists ? RENAME_SWAP : RENAME_EXCL)
        guard renamex_np(staged, dest, flags) == 0 else {
            let err = errno
            try? fm.removeItem(atPath: staged)
            throw Failure.replaceFailed(path: dest, errno: err)
        }
        guard destExists else { return nil }
        do {
            try fm.removeItem(atPath: staged)   // the old bundle, swapped out
            return nil
        } catch {
            return "the new app is installed, but the previous copy at \(staged) couldn't be "
                + "removed (\(error.localizedDescription)). It's safe to delete."
        }
    }
}
