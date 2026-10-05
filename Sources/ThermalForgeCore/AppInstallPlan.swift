//
//  AppInstallPlan.swift
//  ThermalForge
//
//  Which ThermalForge.app `install` puts in /Applications. Decided from the binary
//  that is actually running, so the user always ends up with exactly the build they
//  ran — never another copy that merely shares its version number (#31).
//

import Darwin
import Foundation

public enum AppInstallPlan {

    /// Where the app for this install comes from.
    public enum Source: Equatable {
        /// Copy this ready-made bundle.
        case copyBundle(String)
        /// Assemble a bundle from this build's own app binary and icon.
        case assemble(appBinary: String, icon: String)
        /// Leave /Applications as it is; the text says why and how to fix it.
        case leaveUntouched(String)
    }

    /// What install found on disk, gathered by the caller so the decision is pure.
    public struct Facts: Equatable {
        /// The running thermalforge, symlinks resolved.
        public var runningBinary: String
        /// Set when install re-synced the binary from a newer Homebrew keg: the
        /// keg binary now installed.
        public var resyncedKegBinary: String?
        /// That keg's own app, when present and carrying the keg's version.
        public var resyncedKegApp: String?
        /// Homebrew-keg route only: the bundles install has always accepted
        /// (next to the binary, then Homebrew's opt links) that exist and carry
        /// this version, in that order.
        public var kegApps: [String]
        /// A regular executable ThermalForgeApp next to the running binary — a
        /// SwiftPM build folder's own app.
        public var buildAppBinary: String?
        /// ThermalForge.icns from the package that build came from.
        public var buildIcon: String?
        /// Homebrew's thermalforge binary, if installed (resolved).
        public var homebrewBinary: String?
        /// Homebrew's app, when Homebrew's binary is byte-identical to the running one.
        public var identicalHomebrewApp: String?

        public init(runningBinary: String, resyncedKegBinary: String? = nil,
                    resyncedKegApp: String? = nil, kegApps: [String] = [],
                    buildAppBinary: String? = nil, buildIcon: String? = nil,
                    homebrewBinary: String? = nil, identicalHomebrewApp: String? = nil) {
            self.runningBinary = runningBinary
            self.resyncedKegBinary = resyncedKegBinary
            self.resyncedKegApp = resyncedKegApp
            self.kegApps = kegApps
            self.buildAppBinary = buildAppBinary
            self.buildIcon = buildIcon
            self.homebrewBinary = homebrewBinary
            self.identicalHomebrewApp = identicalHomebrewApp
        }
    }

    /// Whether `path` is a binary inside a Homebrew thermalforge keg.
    public static func isKegBinary(_ path: String) -> Bool {
        path.contains("/Cellar/thermalforge/")
    }

    public static func plan(_ facts: Facts, dest: String = "/Applications/ThermalForge.app") -> Source {
        // The binary was just re-synced from a newer Homebrew keg: the app comes from
        // that same keg, so a new binary never runs beside an older app.
        if let kegBinary = facts.resyncedKegBinary {
            if let app = facts.resyncedKegApp { return .copyBundle(app) }
            return .leaveUntouched(
                "the daemon binary was updated from Homebrew (\(kegBinary)), but that install's "
                + "matching app wasn't found. Reinstall it with `brew reinstall thermalforge`, "
                + "then run `sudo thermalforge install` again.")
        }

        // Homebrew keg: the keg's own app, exactly as install has always chosen it.
        if isKegBinary(facts.runningBinary) {
            if let app = facts.kegApps.first { return .copyBundle(app) }
            return .leaveUntouched(
                "no app bundle was found for this Homebrew install. Reinstall it with "
                + "`brew reinstall thermalforge`, then run `sudo thermalforge install` again.")
        }

        // A SwiftPM build: build the app from this build's own outputs.
        if let appBinary = facts.buildAppBinary {
            if let icon = facts.buildIcon { return .assemble(appBinary: appBinary, icon: icon) }
            return .leaveUntouched(
                "this build's app (\(appBinary)) was found, but not ThermalForge.icns from the "
                + "ThermalForge source folder it was built from. Run ./setup.sh from that folder, or run: "
                + "sudo \(facts.runningBinary) build-app --binary \(appBinary) "
                + "--icon <ThermalForge folder>/ThermalForge.icns --dest \(dest)")
        }

        // Anything else (e.g. the installed copy in /usr/local/bin): Homebrew's app
        // only if it belongs to exactly this binary.
        if let app = facts.identicalHomebrewApp { return .copyBundle(app) }
        let comparison = facts.homebrewBinary.map {
            "it is a different build from Homebrew's \($0)"
        } ?? "no Homebrew copy was found to match it against"
        return .leaveUntouched(
            "the running binary (\(facts.runningBinary)) isn't from a build folder or Homebrew, and "
            + "\(comparison). To install the app from your own build, run ./setup.sh from the "
            + "ThermalForge source folder. To use Homebrew's, run: sudo /opt/homebrew/bin/thermalforge install")
    }

    /// The note to show before replacing the installed binary with a Homebrew
    /// keg's when they differ: install still does what was asked (installs what
    /// ran), but the user learns their own build is being replaced and how to
    /// keep it. Version numbers can't tell two builds apart; contents can.
    public static func replacementNote(runningBinary: String, installPath: String,
                                       installedDiffers: Bool) -> String? {
        guard isKegBinary(runningBinary), installedDiffers else { return nil }
        return "Note: \(installPath) is a different build from this Homebrew copy (\(runningBinary)). "
            + "Installing the Homebrew copy you ran. To keep your own build instead, run it by path "
            + "(sudo /path/to/your/build/thermalforge install) or use ./setup.sh from its source folder."
    }

    // MARK: - Filesystem helpers (no root needed; tested against temp folders)

    /// A regular file (not a symlink, not a folder) that is executable.
    public static func isRegularExecutable(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }

    /// ThermalForge.icns from the ThermalForge package a build folder belongs to:
    /// walk up from `buildFolder` to the first folder whose Package.swift declares
    /// the ThermalForge package, and take its icon if that's a regular file. nil
    /// when the build lives outside the package (a custom build path) or the icon
    /// is missing — never another package's icon.
    public static func packageIcon(above buildFolder: String, maxLevels: Int = 8) -> String? {
        var folder = URL(fileURLWithPath: buildFolder).standardizedFileURL
        for _ in 0...maxLevels {
            let manifest = folder.appendingPathComponent("Package.swift").path
            if let text = try? String(contentsOfFile: manifest, encoding: .utf8),
               text.contains("name: \"ThermalForge\"") {
                let icon = folder.appendingPathComponent("ThermalForge.icns").path
                var info = stat()
                guard lstat(icon, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
                return icon
            }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }
            folder = parent
        }
        return nil
    }
}
