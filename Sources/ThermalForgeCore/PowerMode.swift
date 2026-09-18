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
//  Set with `sudo pmset -c|-b powermode N` — the domain flag must match where
//  the system is drawing power from (AC vs battery), because the *effective*
//  value, readable without privilege from the `powermode` line of `pmset -g`
//  (there is no `pmset -g powermode` query — the key only appears in the full
//  dump), is always taken from the *active* domain. The key is visible in
//  pmset output but not documented in pmset(1), so every set is verified by
//  read-back and every failure degrades to a warning — never a crash, never
//  a hang.
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

/// The `pmset` power domain a mode is written to: `-c` = AC, `-b` = battery.
///
/// A `powermode` set only affects the saved value of the *target* domain,
/// while the value reported by `pmset -g` ("Currently in use") always comes
/// from the *active* domain. The two only agree while the system is on AC —
/// on battery, an AC-only set applies nowhere visible and the verify
/// read-back mismatches forever (field bug 2026-09-17: ~1 hour of false
/// "requested High, system reports Reduced" warnings on a cool machine,
/// ending only when the user re-plugged). Sets therefore always target the
/// domain the system is currently drawing from.
public enum PowerDomain: Sendable {
    case ac
    case battery
}

/// Where the system is drawing power from, as reported by IOKit
/// (`IOPSGetProvidingPowerSourceType`; see `PowerSourceMonitor`) and tracked
/// notification-driven — no polling, no pmset. Feeds the set-domain choice
/// and the rule "on battery: protection only ever asserts reduced, never
/// restores high".
public enum PowerSourceState: Sendable {
    case ac
    case battery
    case unknown

    public var isBattery: Bool { self == .battery }

    public var label: String {
        switch self {
        case .ac: return "on AC"
        case .battery: return "on battery"
        case .unknown: return "power source unknown"
        }
    }
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
    /// Current power source, maintained by an IOKit notification monitor —
    /// thread-safe to read from anywhere.
    var lastPowerSource: PowerSourceState { get }
    /// Set the mode in the given power domain (`-c` for AC, `-b` for battery).
    /// The domain must match where the system is drawing power, otherwise the
    /// set is invisible to the effective (active-domain) read. Throws on failure.
    func setMode(_ mode: PowerMode, in domain: PowerDomain) throws
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

    /// Power source observed by the most recent `readResult()`. Mutated only
    /// Power source, tracked notification-driven by the IOKit monitor (one
    /// initial query, then change notifications — no polling, no pmset).
    /// The monitor callback fires on the main thread while the controller
    /// reads from its own queue, hence the lock; `@unchecked Sendable` rests
    /// on it.
    private let sourceLock = NSLock()
    private var sourceState: PowerSourceState = .unknown
    private let sourceMonitor: PowerSourceMonitor

    public var lastPowerSource: PowerSourceState {
        sourceLock.lock()
        defer { sourceLock.unlock() }
        return sourceState
    }

    /// - pmsetPath: the pmset binary (reads run directly, no privilege).
    /// - sudoPath: the sudo binary (sets are `sudo pmset ...`, exactly the
    ///   invocation the v1 script proved works on the developer's machine).
    public init(pmsetPath: String = "/usr/bin/pmset", sudoPath: String = "/usr/bin/sudo") {
        self.pmsetPath = pmsetPath
        self.sudoPath = sudoPath
        self.sourceMonitor = PowerSourceMonitor()
        sourceMonitor.onChange = { [weak self] source in
            self?.setSourceState(source)
        }
        sourceMonitor.start()
    }

    private func setSourceState(_ source: PowerSourceState) {
        sourceLock.lock()
        defer { sourceLock.unlock() }
        sourceState = source
    }

    public func readResult() -> PowerModeReadResult {
        guard let output = Self.capture(executable: pmsetPath, arguments: ["-g"]) else {
            return .failed("pmset -g failed")
        }
        return Self.parseEffectiveMode(output)
    }

    public func setMode(_ mode: PowerMode, in domain: PowerDomain) throws {
        // The domain flag must match where the system is drawing power from —
        // the effective value pmset reports is always taken from the *active*
        // domain, so a set into the inactive domain is invisible to the
        // read-back (see PowerDomain).
        let flag = domain == .battery ? "-b" : "-c"
        do {
            try Self.runOrThrow(
                executable: sudoPath,
                arguments: ["pmset", flag, "powermode", "\(mode.rawValue)"],
                intent: "power mode \(mode.displayName) (\(domain == .battery ? "battery" : "AC") domain)"
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
