//
//  UserDataTests.swift
//  ThermalForge
//
//  #31: under sudo, calibration and recordings belong to the user who ran sudo,
//  in their home, so the app finds them. The location decision is checked with an
//  injected effective uid, environment and account lookup; the file operations run
//  against a temp folder as the current user. Nothing here needs root or touches
//  the real home folder.
//

import Darwin
import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Where user data goes")
struct UserDataLocationTests {

    private let rootHome = URL(fileURLWithPath: "/var/root", isDirectory: true)
    private func account(_ uid: uid_t) -> (gid: gid_t, home: String)? {
        uid == 1234 ? (20, "/Users/example") : nil
    }

    @Test("Not root: the current user's home, nothing handed over")
    func currentUser() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let location = UserDataLocation.resolve(euid: 1234, environment: ["SUDO_UID": "5678"],
                                                account: account, currentHome: home)
        #expect(location == UserDataLocation(kind: .currentUser, home: home, owner: nil))
    }

    @Test("Root under sudo: the invoking user's home, and they own what's created")
    func sudoUser() {
        let location = UserDataLocation.resolve(euid: 0, environment: ["SUDO_UID": "1234"],
                                                account: account, currentHome: rootHome)
        #expect(location.kind == .sudoUser)
        #expect(location.home.path == "/Users/example")
        #expect(location.owner == UserDataLocation.Owner(uid: 1234, gid: 20))
        #expect(location.appSupport.path == "/Users/example/Library/Application Support/ThermalForge")
    }

    @Test("Root with no usable sudo user: root's own home, root-owned",
          arguments: [[:], ["SUDO_UID": "0"], ["SUDO_UID": "not-a-uid"], ["SUDO_UID": "9999"]])
    func rootShell(environment: [String: String]) {
        let location = UserDataLocation.resolve(euid: 0, environment: environment,
                                                account: account, currentHome: rootHome)
        #expect(location == UserDataLocation(kind: .root, home: rootHome, owner: nil))
    }

    @Test("Recordings go in the user's data folder, or inside --output when given")
    func recordingFolder() {
        let location = UserDataLocation.resolve(euid: 0, environment: ["SUDO_UID": "1234"],
                                                account: account, currentHome: rootHome)
        let byDefault = ThermalLogger.sessionFolder(outputDir: nil, location: location, dirName: "s")
        #expect(byDefault.base.path == "/Users/example")
        #expect(byDefault.components == ["Library", "Application Support", "ThermalForge", "logs", "s"])

        let custom = URL(fileURLWithPath: "/Volumes/Data/runs", isDirectory: true)
        let named = ThermalLogger.sessionFolder(outputDir: custom, location: location, dirName: "s")
        #expect(named.base == custom)
        #expect(named.components == ["s"])
    }
}

@Suite("User files: no symlinks followed, created items handed to the owner")
struct UserFilesTests {

    private let components = ["Library", "Application Support", "ThermalForge"]

    private func tempBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tf-userfiles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func info(_ path: String) -> stat? {
        var st = stat()
        return lstat(path, &st) == 0 ? st : nil
    }

    /// A group this user belongs to that differs from `base`'s group, so a
    /// created item carrying it proves fchown ran (new items otherwise inherit
    /// their folder's group). nil if the user has no second group.
    private func otherGroup(than base: URL) -> gid_t? {
        guard let baseGroup = info(base.path)?.st_gid else { return nil }
        var groups = [gid_t](repeating: 0, count: 64)
        let count = getgroups(Int32(groups.count), &groups)
        guard count > 0 else { return nil }
        return groups.prefix(Int(count)).first { $0 != baseGroup }
    }

    @Test("Write creates the folders and the file, readable back, with no temp file left")
    func writeAndRead() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let files = UserFiles(owner: nil)

        try files.writeFile(base: base, components, name: "calibration.json", data: Data("one".utf8))
        try files.writeFile(base: base, components, name: "calibration.json", data: Data("two".utf8))

        #expect(try files.readFile(base: base, components, name: "calibration.json") == Data("two".utf8))
        let folder = components.reduce(base) { $0.appendingPathComponent($1) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["calibration.json"])
    }

    @Test("With an owner, every folder and file created is handed to them")
    func createdItemsHandedToOwner() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        guard let group = otherGroup(than: base) else { return }   // nothing distinct to prove with
        let files = UserFiles(owner: UserDataLocation.Owner(uid: getuid(), gid: group))

        try files.writeFile(base: base, components, name: "calibration.json", data: Data("x".utf8))
        let handle = try files.createFile(base: base, components + ["logs", "s"], name: "thermal.csv")
        try handle.close()

        var path = base.path
        for name in components + ["logs", "s"] {
            path += "/" + name
            #expect(info(path)?.st_uid == getuid())
            #expect(info(path)?.st_gid == group, "\(name)")
        }
        let calibration = base.path + "/" + components.joined(separator: "/") + "/calibration.json"
        #expect(info(calibration)?.st_gid == group)
        #expect(info(path + "/thermal.csv")?.st_gid == group)
    }

    @Test("A symlinked folder on the way is refused, and nothing is written through it")
    func symlinkedFolderRefused() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let elsewhere = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let library = base.appendingPathComponent("Library/Application Support")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: library.appendingPathComponent("ThermalForge"),
                                                   withDestinationURL: elsewhere)
        let files = UserFiles(owner: nil)

        #expect(throws: UserFiles.Failure.self) {
            try files.writeFile(base: base, components, name: "calibration.json", data: Data("x".utf8))
        }
        #expect(throws: UserFiles.Failure.self) {
            _ = try files.readFile(base: base, components, name: "calibration.json")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test("A symlink at the file's name is replaced on write and refused on read; its target is untouched")
    func symlinkAtFileName() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("target.txt")
        try Data("keep".utf8).write(to: target)
        let files = UserFiles(owner: nil)
        try files.ensureDirectory(base: base, components)
        let folder = components.reduce(base) { $0.appendingPathComponent($1) }
        let link = folder.appendingPathComponent("calibration.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: UserFiles.Failure.self) {
            _ = try files.readFile(base: base, components, name: "calibration.json")
        }
        try files.writeFile(base: base, components, name: "calibration.json", data: Data("new".utf8))

        #expect(try Data(contentsOf: target) == Data("keep".utf8))
        #expect(info(link.path).map { ($0.st_mode & S_IFMT) == S_IFREG } == true)
    }

    @Test("Creating a file never reuses or writes through an existing one")
    func createIsExclusive() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let files = UserFiles(owner: nil)

        let handle = try files.createFile(base: base, components, name: "thermal.csv")
        try handle.write(contentsOf: Data("a,b\n".utf8))
        try handle.close()

        #expect(throws: UserFiles.Failure.self) {
            _ = try files.createFile(base: base, components, name: "thermal.csv")
        }
        #expect(try files.readFile(base: base, components, name: "thermal.csv") == Data("a,b\n".utf8))
    }

    @Test("Reading or removing what isn't there creates nothing")
    func missingCreatesNothing() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let files = UserFiles(owner: nil)

        #expect(try files.readFile(base: base, components, name: "calibration.json") == nil)
        #expect(try files.removeFile(base: base, components, name: "calibration.json") == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
    }

    @Test("Remove deletes the file, or a symlink itself, never its target")
    func remove() throws {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let files = UserFiles(owner: nil)
        try files.writeFile(base: base, components, name: "calibration.json", data: Data("x".utf8))
        #expect(try files.removeFile(base: base, components, name: "calibration.json"))
        #expect(try files.readFile(base: base, components, name: "calibration.json") == nil)

        let target = base.appendingPathComponent("target.txt")
        try Data("keep".utf8).write(to: target)
        let folder = components.reduce(base) { $0.appendingPathComponent($1) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("calibration.json"),
                                                   withDestinationURL: target)
        #expect(try files.removeFile(base: base, components, name: "calibration.json"))
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
    }
}

@Suite("Calibration is saved and loaded at the user's location")
struct CalibrationLocationTests {

    private func location() throws -> UserDataLocation {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tf-calhome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return UserDataLocation(kind: .currentUser, home: home, owner: nil)
    }

    private func sample() -> CalibrationData {
        CalibrationData(machine: "Mac00,0", fans: 2, maxRPM: 5000, minRPM: 1000,
                        calibratedAt: "2026-01-01T00:00:00Z", mode: "quick", measurements: [])
    }

    @Test("Saved calibration loads back from the same place")
    func roundTrip() throws {
        let loc = try location()
        defer { try? FileManager.default.removeItem(at: loc.home) }

        var logged: [String] = []
        #expect(CalibrationData.load(from: loc, logError: { logged.append($0) }) == nil)
        try sample().save(to: loc)
        #expect(FileManager.default.fileExists(atPath: loc.appSupport.appendingPathComponent("calibration.json").path))
        #expect(CalibrationData.load(from: loc, logError: { logged.append($0) })?.machine == "Mac00,0")
        #expect(try CalibrationData.remove(from: loc))
        #expect(CalibrationData.load(from: loc, logError: { logged.append($0) }) == nil)
        #expect(logged.isEmpty)
    }

    @Test("A corrupted calibration is removed on load")
    func corrupted() throws {
        let loc = try location()
        defer { try? FileManager.default.removeItem(at: loc.home) }
        try loc.files.writeFile(base: loc.home, UserDataLocation.appSupportComponents,
                                name: "calibration.json", data: Data("not json".utf8))

        var logged: [String] = []
        #expect(CalibrationData.load(from: loc, logError: { logged.append($0) }) == nil)
        #expect(logged == ["Calibration file is corrupted (JSON decode failed); deleting"])
        #expect(!FileManager.default.fileExists(atPath: loc.appSupport.appendingPathComponent("calibration.json").path))
    }
}
