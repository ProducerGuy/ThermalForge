//
//  PowerMode.swift
//  ThermalForge
//
//  Apple's system-wide power modes — the one protection a fan curve cannot
//  provide on its own: capping the chip itself.
//
//      1 = reduced performance   (power/clock capped — cannot overheat)
//      2 = high performance
//
//  Set with `sudo pmset -c powermode N` (AC domain, privileged). The
//  *effective* value is readable without privilege from the `powermode` line
//  of `pmset -g` (there is no `pmset -g powermode` query — the key only
//  appears in the full dump). The key is visible in pmset output but not
//  documented in pmset(1), so every set is verified by read-back and every
//  failure degrades to a warning — never a crash, never a hang.
//

import Foundation

/// Apple's system-wide power modes.
public enum PowerMode: Int, Equatable, Sendable, CustomStringConvertible {
    case reduced = 1
    case high = 2

    public var displayName: String {
        switch self {
        case .reduced: return "Reduced performance"
        case .high: return "High performance"
        }
    }

    public var description: String { displayName }
}

/// What a `pmset -g` read told us about the effective power mode.
public enum PowerModeReadResult: Equatable, Sendable {
    /// The effective mode, as currently in use.
    case mode(PowerMode)
    /// The key is present but holds a value we don't know (future Apple mode).
    case unknownValue(Int)
    /// pmset ran cleanly but reported no `powermode` key at all (older OS).
    case keyAbsent
    /// pmset could not be run/parsed.
    case failed(String)
}

public enum PowerModeError: Error, CustomStringConvertible {
    /// The `pmset` set could not be run (spawn failure, or non-zero exit —
    /// including sudo refusing without a TTY on machines lacking the
    /// passwordless sudoers entry).
    case setFailed(String)

    public var description: String {
        switch self {
        case .setFailed(let detail):
            return "Failed to set power mode: \(detail)"
        }
    }
}

/// Access to the system power mode. Protocol so tests (and future backends)
/// can stub it; the production implementation shells out to `pmset`.
public protocol PowerModeBackend: Sendable {
    /// Read the effective mode. Never throws — failures are reported as
    /// `.failed` so a broken read can't take down the control loop.
    func readResult() -> PowerModeReadResult
    /// Set the AC-power domain mode (`-c`). Throws on failure.
    func setMode(_ mode: PowerMode) throws
}

/// `pmset`-backed power mode access.
///
/// Setting goes through `sudo` — the development machines carry a
/// passwordless sudoers entry for the current user. A GUI app has no TTY,
/// so on a machine WITHOUT that entry sudo fails fast with a diagnostic
/// instead of hanging on a password prompt; the controller turns that into
/// a warning and keeps everything else working.
public final class PmsetPowerModeBackend: PowerModeBackend, @unchecked Sendable {
    private let pmsetPath: String
    private let sudoPath: String

    /// - pmsetPath: the pmset binary (reads run directly, no privilege).
    /// - sudoPath: the sudo binary (sets are `sudo pmset ...`, exactly the
    ///   invocation the v1 script proved works on the developer's machine).
    public init(pmsetPath: String = "/usr/bin/pmset", sudoPath: String = "/usr/bin/sudo") {
        self.pmsetPath = pmsetPath
        self.sudoPath = sudoPath
    }

    public func readResult() -> PowerModeReadResult {
        guard let output = Self.capture(executable: pmsetPath, arguments: ["-g"]) else {
            return .failed("pmset -g failed")
        }
        return Self.parseEffectiveMode(output)
    }

    public func setMode(_ mode: PowerMode) throws {
        do {
            try Self.runOrThrow(
                executable: sudoPath,
                arguments: ["pmset", "-c", "powermode", "\(mode.rawValue)"],
                intent: "power mode \(mode.displayName)"
            )
        } catch let error as PowerModeError {
            throw error   // already carries the full diagnostic
        } catch {
            throw PowerModeError.setFailed(
                "could not set power mode \(mode.displayName): \(error)"
            )
        }
    }

    // MARK: - Parsing

    /// Parse the *effective* mode from `pmset -g` output.
    ///
    /// The first matching line is in the "Currently in use" section (the
    /// effective value). The token is matched exactly, so a `lowpowermode`
    /// line (Intel key) can never match.
    public static func parseEffectiveMode(_ output: String) -> PowerModeReadResult {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, fields[0] == "powermode",
                  let raw = Int(fields[1]) else { continue }
            if let mode = PowerMode(rawValue: raw) {
                return .mode(mode)
            }
            return .unknownValue(raw)
        }
        return .keyAbsent
    }

    // MARK: - Process plumbing

    /// Run a command, return stdout, or nil on any failure.
    private static func capture(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// Run a command; throw `PowerModeError.setFailed` with the stderr detail
    /// on a non-zero exit, or if the process cannot be spawned at all.
    private static func runOrThrow(executable: String, arguments: [String], intent: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            throw PowerModeError.setFailed("could not run \(executable) (\(intent)): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let suffix = detail.isEmpty ? "" : " — \(detail)"
            throw PowerModeError.setFailed("\(intent) exited \(process.terminationStatus)\(suffix)")
        }
    }
}
