//
//  AppBundleAssemblerTests.swift
//  ThermalForge
//
//  #31: the shared app assembler and its safe file copy. Root only ever installs
//  the exact regular file it checked, never through a symlink or over an existing
//  file, and a bad source leaves the installed app as it was. Temp folders only.
//

import Darwin
import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("App bundle assembler (#31)")
struct AppBundleAssemblerTests {

    private func scratchDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tf-assembler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL, mode: mode_t) throws {
        try Data(text.utf8).write(to: url)
        chmod(url.path, mode)
    }

    private func mode(_ path: String) -> mode_t {
        var info = stat()
        lstat(path, &info)
        return info.st_mode & 0o7777
    }

    private func isRegular(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    // MARK: Safe copy

    @Test("A regular file is copied byte for byte with its permissions")
    func copiesRegularFile() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("app")
        try write("app-binary-bytes", to: src, mode: 0o755)
        let dst = root.appendingPathComponent("copy").path

        try SafeFileCopy.copyRegularFile(from: src.path, to: dst, requireExecutable: true)
        #expect(try String(contentsOfFile: dst, encoding: .utf8) == "app-binary-bytes")
        #expect(mode(dst) == 0o755)
        #expect(isRegular(dst))
    }

    @Test("A symlink is refused, never followed, and nothing is written")
    func refusesSymlink() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try write("secret", to: target, mode: 0o755)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let dst = root.appendingPathComponent("copy").path

        #expect(throws: SafeFileCopy.Failure.notRegularFile(path: link.path)) {
            try SafeFileCopy.copyRegularFile(from: link.path, to: dst)
        }
        #expect(!FileManager.default.fileExists(atPath: dst))
    }

    @Test("A folder or a FIFO is refused, and a FIFO can't stall the copy")
    func refusesSpecialFiles() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fifo = root.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o644) == 0)

        #expect(throws: SafeFileCopy.Failure.notRegularFile(path: folder.path)) {
            try SafeFileCopy.copyRegularFile(from: folder.path, to: root.appendingPathComponent("c1").path)
        }
        #expect(throws: SafeFileCopy.Failure.notRegularFile(path: fifo.path)) {
            try SafeFileCopy.copyRegularFile(from: fifo.path, to: root.appendingPathComponent("c2").path)
        }
    }

    @Test("A non-executable app binary is refused")
    func refusesNonExecutable() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("app")
        try write("x", to: src, mode: 0o644)
        #expect(throws: SafeFileCopy.Failure.notExecutable(path: src.path)) {
            try SafeFileCopy.copyRegularFile(from: src.path, to: root.appendingPathComponent("c").path,
                                             requireExecutable: true)
        }
    }

    @Test("Anything already at the destination is never overwritten or written through")
    func neverOverwrites() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("app")
        try write("new", to: src, mode: 0o755)
        let existing = root.appendingPathComponent("existing")
        try write("old", to: existing, mode: 0o644)

        #expect(throws: (any Error).self) {
            try SafeFileCopy.copyRegularFile(from: src.path, to: existing.path)
        }
        #expect(try String(contentsOfFile: existing.path, encoding: .utf8) == "old")
    }

    @Test("setuid and setgid bits are never carried into the copy")
    func dropsSetuid() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("app")
        try write("x", to: src, mode: 0o755)
        chmod(src.path, 0o6755)
        let dst = root.appendingPathComponent("copy").path
        try SafeFileCopy.copyRegularFile(from: src.path, to: dst)
        #expect(mode(dst) & 0o6000 == 0)
        #expect(mode(dst) & 0o777 == 0o755)
    }

    // MARK: Assembler

    private func sources(in root: URL) throws -> (binary: URL, icon: URL) {
        let binary = root.appendingPathComponent("ThermalForgeApp")
        try write("app-binary", to: binary, mode: 0o755)
        let icon = root.appendingPathComponent("ThermalForge.icns")
        try write("icon-bytes", to: icon, mode: 0o644)
        return (binary, icon)
    }

    @Test("The assembler builds a complete bundle from the checked files")
    func assemblesBundle() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (binary, icon) = try sources(in: root)
        let dest = root.appendingPathComponent("ThermalForge.app").path

        try AppBundleAssembler.assemble(binary: binary.path, icon: icon.path, dest: dest)
        let exe = "\(dest)/Contents/MacOS/ThermalForgeApp"
        #expect(try String(contentsOfFile: exe, encoding: .utf8) == "app-binary")
        #expect(mode(exe) == 0o755)
        #expect(try String(contentsOfFile: "\(dest)/Contents/Resources/AppIcon.icns", encoding: .utf8) == "icon-bytes")
        let plist = try #require(NSDictionary(contentsOfFile: "\(dest)/Contents/Info.plist"))
        #expect(plist["CFBundleExecutable"] as? String == "ThermalForgeApp")
        #expect(plist["CFBundleShortVersionString"] as? String == ThermalForgeVersion.current)
        #expect(!FileManager.default.fileExists(atPath: AtomicReplace.stagingPath(for: dest)))
    }

    @Test("Reassembling replaces the old bundle completely")
    func replacesOldBundle() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (binary, icon) = try sources(in: root)
        let dest = root.appendingPathComponent("ThermalForge.app")
        try FileManager.default.createDirectory(at: dest.appendingPathComponent("Contents/MacOS"),
                                                withIntermediateDirectories: true)
        try write("stale", to: dest.appendingPathComponent("Contents/stale-file"), mode: 0o644)

        try AppBundleAssembler.assemble(binary: binary.path, icon: icon.path, dest: dest.path)
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("Contents/stale-file").path))
        #expect(isRegular(dest.appendingPathComponent("Contents/MacOS/ThermalForgeApp").path))
    }

    @Test("A bad source leaves the installed app exactly as it was, with nothing half-built left behind")
    func badSourceKeepsOldApp() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, icon) = try sources(in: root)
        let target = root.appendingPathComponent("target")
        try write("not-our-app", to: target, mode: 0o755)
        let linkedBinary = root.appendingPathComponent("linked-app")
        try FileManager.default.createSymbolicLink(at: linkedBinary, withDestinationURL: target)

        let dest = root.appendingPathComponent("ThermalForge.app")
        let oldExe = dest.appendingPathComponent("Contents/MacOS/ThermalForgeApp")
        try FileManager.default.createDirectory(at: oldExe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write("installed-app", to: oldExe, mode: 0o755)

        #expect(throws: SafeFileCopy.Failure.notRegularFile(path: linkedBinary.path)) {
            try AppBundleAssembler.assemble(binary: linkedBinary.path, icon: icon.path, dest: dest.path)
        }
        #expect(try String(contentsOfFile: oldExe.path, encoding: .utf8) == "installed-app")
        #expect(!FileManager.default.fileExists(atPath: AtomicReplace.stagingPath(for: dest.path)))

        // A missing icon is the same: the installed app stays.
        #expect(throws: (any Error).self) {
            try AppBundleAssembler.assemble(binary: target.path, icon: root.appendingPathComponent("absent.icns").path,
                                            dest: dest.path)
        }
        #expect(try String(contentsOfFile: oldExe.path, encoding: .utf8) == "installed-app")
    }

    // MARK: Atomic replace

    @Test("An existing app is swapped for the new one in one step, and the old copy is cleaned up")
    func swapsExistingApp() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("ThermalForge.app")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try write("old", to: dest.appendingPathComponent("marker"), mode: 0o644)
        let staged = URL(fileURLWithPath: AtomicReplace.stagingPath(for: dest.path))
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try write("new", to: staged.appendingPathComponent("marker"), mode: 0o644)

        #expect(try AtomicReplace.replace(dest.path, with: staged.path) == nil)
        #expect(try String(contentsOfFile: dest.appendingPathComponent("marker").path, encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: staged.path))   // the old copy, removed
    }

    @Test("With nothing installed yet, the new app is simply moved into place")
    func placesFirstApp() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("ThermalForge.app")
        let staged = URL(fileURLWithPath: AtomicReplace.stagingPath(for: dest.path))
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try write("new", to: staged.appendingPathComponent("marker"), mode: 0o644)

        #expect(try AtomicReplace.replace(dest.path, with: staged.path) == nil)
        #expect(try String(contentsOfFile: dest.appendingPathComponent("marker").path, encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("If the swap can't happen, the installed app stays exactly as it was and the failure is loud")
    func failedSwapKeepsOldApp() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("ThermalForge.app")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try write("old", to: dest.appendingPathComponent("marker"), mode: 0o644)
        let missing = AtomicReplace.stagingPath(for: dest.path)   // nothing was staged

        #expect(throws: AtomicReplace.Failure.replaceFailed(path: dest.path, errno: ENOENT)) {
            try AtomicReplace.replace(dest.path, with: missing)
        }
        #expect(try String(contentsOfFile: dest.appendingPathComponent("marker").path, encoding: .utf8) == "old")
        #expect(AtomicReplace.Failure.replaceFailed(path: dest.path, errno: ENOENT).description
                    .contains("The existing app is untouched."))
    }
}

/// Under sudo, every item of the app bundle is handed to the user who ran sudo, so
/// the app can be trashed or replaced without a password. Checked without root by
/// handing everything to a second group this user belongs to: new items otherwise
/// inherit their folder's group, so carrying that group proves the hand-over ran.
@Suite("App bundle ownership (#31)")
struct BundleOwnershipTests {

    private func scratchDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tf-ownership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func info(_ path: String) -> stat? {
        var st = stat()
        return lstat(path, &st) == 0 ? st : nil
    }

    /// An owner with this user's uid and a group different from `root`'s, or nil
    /// if the user has no second group.
    private func owner(differingFrom root: URL) -> UserDataLocation.Owner? {
        guard let rootGroup = info(root.path)?.st_gid else { return nil }
        var groups = [gid_t](repeating: 0, count: 64)
        let count = getgroups(Int32(groups.count), &groups)
        guard count > 0, let group = groups.prefix(Int(count)).first(where: { $0 != rootGroup }) else { return nil }
        return UserDataLocation.Owner(uid: getuid(), gid: group)
    }

    /// Every path in the tree, the root included, without following symlinks.
    private func allItems(_ root: String) -> [String] {
        var items = [root]
        let enumerator = FileManager.default.enumerator(atPath: root)
        while let relative = enumerator?.nextObject() as? String { items.append(root + "/" + relative) }
        return items
    }

    private func sources(in root: URL) throws -> (URL, URL) {
        let binary = root.appendingPathComponent("ThermalForgeApp")
        try Data("app-binary".utf8).write(to: binary)
        chmod(binary.path, 0o755)
        let icon = root.appendingPathComponent("ThermalForge.icns")
        try Data("icon-bytes".utf8).write(to: icon)
        return (binary, icon)
    }

    @Test("Assembled with an owner: the bundle and every item in it carry the owner")
    func assembledBundleHandedOver() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        guard let owner = owner(differingFrom: root) else { return }
        let (binary, icon) = try sources(in: root)
        let dest = root.appendingPathComponent("ThermalForge.app").path

        try AppBundleAssembler.assemble(binary: binary.path, icon: icon.path, dest: dest, owner: owner)

        let items = allItems(dest)
        #expect(items.count == 7)   // bundle, Contents, MacOS, Resources, Info.plist, binary, icon
        for item in items {
            #expect(info(item)?.st_uid == owner.uid, "\(item)")
            #expect(info(item)?.st_gid == owner.gid, "\(item)")
        }
    }

    @Test("Assembled with no owner: nothing is handed over")
    func noOwnerNoHandOver() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        guard let other = owner(differingFrom: root) else { return }
        let (binary, icon) = try sources(in: root)
        let dest = root.appendingPathComponent("ThermalForge.app").path

        try AppBundleAssembler.assemble(binary: binary.path, icon: icon.path, dest: dest, owner: nil)
        #expect(info(dest)?.st_gid != other.gid)
        #expect(info(dest + "/Contents/Info.plist")?.st_gid != other.gid)
    }

    @Test("A copied bundle (the Homebrew routes) is handed over completely, symlinks as links")
    func copiedBundleHandedOver() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        guard let owner = owner(differingFrom: root) else { return }
        let keg = root.appendingPathComponent("keg/ThermalForge.app")
        try FileManager.default.createDirectory(at: keg.appendingPathComponent("Contents/MacOS"),
                                                withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: keg.appendingPathComponent("Contents/MacOS/ThermalForgeApp"))
        let outside = root.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: keg.appendingPathComponent("Contents/link"),
                                                   withDestinationURL: outside)
        let staging = root.appendingPathComponent("ThermalForge.app.staged")
        try FileManager.default.copyItem(at: keg, to: staging)

        try BundleOwnership.handOver(staging.path, to: owner)

        for item in allItems(staging.path) {
            #expect(info(item)?.st_gid == owner.gid, "\(item)")
        }
        #expect(info(outside.path)?.st_gid != owner.gid)   // the link's target is untouched
    }

    @Test("A staged path that is itself a symlink is refused, and its target is untouched")
    func symlinkedBundleRefused() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        guard let owner = owner(differingFrom: root) else { return }
        let target = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent("ThermalForge.app.staged")
        try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: target)

        #expect(throws: UserFiles.Failure.self) { try BundleOwnership.handOver(staging.path, to: owner) }
        #expect(info(target.path)?.st_gid != owner.gid)
    }

    @Test("A special file in the bundle fails the hand-over")
    func specialFileRefused() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        guard let owner = owner(differingFrom: root) else { return }
        let staging = root.appendingPathComponent("ThermalForge.app.staged")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        #expect(mkfifo(staging.appendingPathComponent("pipe").path, 0o644) == 0)

        #expect(throws: UserFiles.Failure.self) { try BundleOwnership.handOver(staging.path, to: owner) }
    }
}
