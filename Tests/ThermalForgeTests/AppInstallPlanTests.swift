//
//  AppInstallPlanTests.swift
//  ThermalForge
//
//  #31: install puts exactly the build that was run into /Applications. One test
//  per install route (A setup.sh, B explicit path, C Homebrew, D1/D2 a bare
//  `sudo thermalforge` with Homebrew or /usr/local/bin first), plus the cases that
//  leave /Applications alone and the filesystem helpers, against temp folders.
//

import Darwin
import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("App install plan (#31)")
struct AppInstallPlanTests {

    // Neutral example locations: a source checkout, its SwiftPM build, Homebrew.
    private let buildBinary = "/src/ThermalForge/.build/arm64-apple-macosx/release/thermalforge"
    private let buildApp = "/src/ThermalForge/.build/arm64-apple-macosx/release/ThermalForgeApp"
    private let repoIcon = "/src/ThermalForge/ThermalForge.icns"
    private let kegBinary = "/opt/homebrew/Cellar/thermalforge/9.9.9/bin/thermalforge"
    private let kegApp = "/opt/homebrew/Cellar/thermalforge/9.9.9/ThermalForge.app"
    private let installed = "/usr/local/bin/thermalforge"

    // MARK: Routes

    @Test("A, setup.sh: the app is assembled from the build that ran")
    func routeSetupScript() {
        let facts = AppInstallPlan.Facts(runningBinary: buildBinary, buildAppBinary: buildApp,
                                         buildIcon: repoIcon, homebrewBinary: kegBinary)
        #expect(AppInstallPlan.plan(facts) == .assemble(appBinary: buildApp, icon: repoIcon))
    }

    @Test("B, explicit path: the build's app, never Homebrew's, even at the same version")
    func routeExplicitPath() {
        // Homebrew is installed with a same-version app; it must not be used.
        let facts = AppInstallPlan.Facts(runningBinary: buildBinary, kegApps: [],
                                         buildAppBinary: buildApp, buildIcon: repoIcon,
                                         homebrewBinary: kegBinary, identicalHomebrewApp: nil)
        #expect(AppInstallPlan.plan(facts) == .assemble(appBinary: buildApp, icon: repoIcon))
    }

    @Test("C, Homebrew: the keg's own app, as before")
    func routeHomebrew() {
        let facts = AppInstallPlan.Facts(runningBinary: kegBinary, kegApps: [kegApp])
        #expect(AppInstallPlan.plan(facts) == .copyBundle(kegApp))
        #expect(AppInstallPlan.replacementNote(runningBinary: kegBinary, installPath: installed,
                                               installedDiffers: false) == nil)
    }

    @Test("D1, bare sudo with Homebrew first: installs what ran, and says a different build is being replaced")
    func routeBareSudoHomebrewFirst() throws {
        let facts = AppInstallPlan.Facts(runningBinary: kegBinary, kegApps: [kegApp])
        #expect(AppInstallPlan.plan(facts) == .copyBundle(kegApp))
        let note = try #require(AppInstallPlan.replacementNote(runningBinary: kegBinary,
                                                               installPath: installed,
                                                               installedDiffers: true))
        #expect(note.contains(installed))
        #expect(note.contains(kegBinary))
        #expect(note.contains("./setup.sh"))
    }

    @Test("D2, bare sudo with /usr/local/bin first: Homebrew's app only if the binaries are identical")
    func routeBareSudoLocalFirst() {
        let identical = AppInstallPlan.Facts(runningBinary: installed, homebrewBinary: kegBinary,
                                             identicalHomebrewApp: kegApp)
        #expect(AppInstallPlan.plan(identical) == .copyBundle(kegApp))

        let different = AppInstallPlan.Facts(runningBinary: installed, homebrewBinary: kegBinary)
        guard case .leaveUntouched(let reason) = AppInstallPlan.plan(different) else {
            Issue.record("expected /Applications left alone")
            return
        }
        #expect(reason.contains("different build from Homebrew's \(kegBinary)"))
        #expect(reason.contains("./setup.sh"))
    }

    @Test("D2 after a re-sync from a newer Homebrew keg: the app comes from that same keg")
    func routeResyncedFromKeg() {
        let newerKegBinary = "/opt/homebrew/Cellar/thermalforge/9.9.10/bin/thermalforge"
        let newerKegApp = "/opt/homebrew/Cellar/thermalforge/9.9.10/ThermalForge.app"
        // The running copy differs from Homebrew's (it's older), which on its own
        // would leave /Applications alone; the re-sync must win.
        let facts = AppInstallPlan.Facts(runningBinary: installed, resyncedKegBinary: newerKegBinary,
                                         resyncedKegApp: newerKegApp, homebrewBinary: newerKegBinary)
        #expect(AppInstallPlan.plan(facts) == .copyBundle(newerKegApp))
    }

    @Test("A re-sync whose keg has no matching app says so; never a new binary beside an older app")
    func resyncWithoutKegApp() {
        let newerKegBinary = "/opt/homebrew/Cellar/thermalforge/9.9.10/bin/thermalforge"
        let facts = AppInstallPlan.Facts(runningBinary: installed, resyncedKegBinary: newerKegBinary,
                                         homebrewBinary: newerKegBinary, identicalHomebrewApp: kegApp)
        guard case .leaveUntouched(let reason) = AppInstallPlan.plan(facts) else {
            Issue.record("expected /Applications left alone")
            return
        }
        #expect(reason.contains(newerKegBinary))
        #expect(reason.contains("brew reinstall thermalforge"))
    }

    // MARK: Never a wrong app, never a silent skip

    @Test("A matching version alone never selects an app for a non-keg binary")
    func versionAloneIsNotEnough() {
        // Same-version keg apps exist, but the running binary isn't the keg's.
        let facts = AppInstallPlan.Facts(runningBinary: installed, kegApps: [kegApp],
                                         homebrewBinary: kegBinary)
        guard case .leaveUntouched = AppInstallPlan.plan(facts) else {
            Issue.record("a version match alone must not pick an app")
            return
        }
    }

    @Test("A build without its icon leaves /Applications alone and gives the exact fix")
    func buildWithoutIcon() {
        let facts = AppInstallPlan.Facts(runningBinary: buildBinary, buildAppBinary: buildApp)
        guard case .leaveUntouched(let reason) = AppInstallPlan.plan(facts) else {
            Issue.record("expected /Applications left alone")
            return
        }
        #expect(reason.contains("./setup.sh"))
        #expect(reason.contains("build-app --binary \(buildApp)"))
    }

    @Test("A Homebrew keg without its app says so, instead of grabbing another copy")
    func kegWithoutApp() {
        let facts = AppInstallPlan.Facts(runningBinary: kegBinary, kegApps: [])
        guard case .leaveUntouched(let reason) = AppInstallPlan.plan(facts) else {
            Issue.record("expected /Applications left alone")
            return
        }
        #expect(reason.contains("brew reinstall thermalforge"))
    }

    @Test("No Homebrew to compare against is stated plainly")
    func noHomebrewToCompare() {
        let facts = AppInstallPlan.Facts(runningBinary: installed)
        guard case .leaveUntouched(let reason) = AppInstallPlan.plan(facts) else {
            Issue.record("expected /Applications left alone")
            return
        }
        #expect(reason.contains("no Homebrew copy was found"))
    }

    @Test("Only a Homebrew keg binary triggers the replacement note")
    func noteOnlyForKeg() {
        #expect(AppInstallPlan.replacementNote(runningBinary: buildBinary, installPath: installed,
                                               installedDiffers: true) == nil)
    }

    // MARK: Filesystem helpers

    private func scratchDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tf-app-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Only a regular, executable file counts as the build's app binary")
    func regularExecutableOnly() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let exe = root.appendingPathComponent("ThermalForgeApp")
        try Data("x".utf8).write(to: exe)
        chmod(exe.path, 0o755)
        let plain = root.appendingPathComponent("plain")
        try Data("x".utf8).write(to: plain)
        chmod(plain.path, 0o644)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: exe)

        #expect(AppInstallPlan.isRegularExecutable(exe.path))
        #expect(!AppInstallPlan.isRegularExecutable(plain.path))
        #expect(!AppInstallPlan.isRegularExecutable(link.path))   // a symlink is never trusted
        #expect(!AppInstallPlan.isRegularExecutable(root.path))   // nor a folder
        #expect(!AppInstallPlan.isRegularExecutable(root.appendingPathComponent("absent").path))
    }

    @Test("The icon comes from the ThermalForge package the build folder belongs to")
    func iconFromOwnPackage() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let pkg = root.appendingPathComponent("ThermalForge")
        let build = pkg.appendingPathComponent(".build/arm64-apple-macosx/release")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data("let package = Package(\n    name: \"ThermalForge\",\n)".utf8)
            .write(to: pkg.appendingPathComponent("Package.swift"))
        try Data("icns".utf8).write(to: pkg.appendingPathComponent("ThermalForge.icns"))

        #expect(AppInstallPlan.packageIcon(above: build.path) == pkg.appendingPathComponent("ThermalForge.icns").path)
    }

    @Test("No icon from another package, a missing icon, a symlinked icon, or a build outside the package")
    func iconNeverWrong() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }

        // Another package's manifest: its icon must not be used.
        let other = root.appendingPathComponent("Other")
        let otherBuild = other.appendingPathComponent(".build/release")
        try FileManager.default.createDirectory(at: otherBuild, withIntermediateDirectories: true)
        try Data("let package = Package(name: \"Other\")".utf8).write(to: other.appendingPathComponent("Package.swift"))
        try Data("icns".utf8).write(to: other.appendingPathComponent("ThermalForge.icns"))
        #expect(AppInstallPlan.packageIcon(above: otherBuild.path) == nil)

        // ThermalForge package with no icon.
        let bare = root.appendingPathComponent("Bare")
        let bareBuild = bare.appendingPathComponent(".build/release")
        try FileManager.default.createDirectory(at: bareBuild, withIntermediateDirectories: true)
        try Data("name: \"ThermalForge\"".utf8).write(to: bare.appendingPathComponent("Package.swift"))
        #expect(AppInstallPlan.packageIcon(above: bareBuild.path) == nil)

        // ThermalForge package whose icon is a symlink.
        let linked = root.appendingPathComponent("Linked")
        let linkedBuild = linked.appendingPathComponent(".build/release")
        try FileManager.default.createDirectory(at: linkedBuild, withIntermediateDirectories: true)
        try Data("name: \"ThermalForge\"".utf8).write(to: linked.appendingPathComponent("Package.swift"))
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("ThermalForge.icns"),
                                                   withDestinationURL: other.appendingPathComponent("ThermalForge.icns"))
        #expect(AppInstallPlan.packageIcon(above: linkedBuild.path) == nil)

        // A build folder with no package above it (a custom build path).
        let loose = root.appendingPathComponent("loose/build/release")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        #expect(AppInstallPlan.packageIcon(above: loose.path) == nil)
    }
}
