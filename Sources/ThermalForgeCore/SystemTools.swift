//
//  SystemTools.swift
//  ThermalForge
//
//  Small process helpers for the CLI's install/uninstall/auto paths: finding the
//  running executable without trusting argv[0], and running a helper tool so a
//  launch failure is reported instead of ignored and its output never reaches the
//  terminal except inside our own failure message.
//

import Darwin
import Foundation

public enum SystemTools {

    /// The real path of the running executable, from dyld's record of what was
    /// executed (`_NSGetExecutablePath`) resolved through `realpath`. Unlike
    /// argv[0], this doesn't depend on how the command was typed or on Foundation
    /// turning a bare name into a path. nil only if the system can't say.
    public static func currentExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)   // reports the buffer size needed
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0,
              let resolved = realpath(buffer, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// How a helper tool run ended.
    public enum ToolRun: Equatable {
        /// The tool ran; `output` is what it printed (stdout and stderr together,
        /// trimmed), captured so it never reaches the terminal on its own.
        case exited(Int32, output: String)
        /// The tool never started; `reason` says why.
        case notLaunched(String)
    }

    /// Run a tool and wait for it. Its output is captured, not passed through: the
    /// caller prints its own message and includes the tool's text only when
    /// reporting a failure. A launch failure comes back as `.notLaunched` rather
    /// than being dropped, and the exit status is read only for a process that
    /// actually started: reading it from one that never launched raises
    /// NSInvalidArgumentException ("task not launched") and crashes.
    public static func run(_ path: String, _ arguments: [String]) -> ToolRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return .notLaunched(error.localizedDescription)
        }
        // Drain before waiting, so a full pipe can never stall the tool.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .exited(process.terminationStatus, output: output)
    }

    /// "<tool> exit <status>", plus the tool's own text when it printed any: the
    /// detail for a failure message.
    public static func exitDetail(tool: String, status: Int32, output: String) -> String {
        output.isEmpty ? "\(tool) exit \(status)" : "\(tool) exit \(status): \(output)"
    }

    /// Whether a process named `name` is running: for `uid`, or for any user when
    /// nil. nil when pgrep can't answer.
    public static func processRunning(_ name: String = "ThermalForgeApp", uid: uid_t?) -> Bool? {
        var arguments = ["-x"]
        if let uid { arguments += ["-u", "\(uid)"] }
        arguments.append(name)
        switch run("/usr/bin/pgrep", arguments) {
        case .exited(0, _): return true
        case .exited(1, _): return false
        default: return nil
        }
    }

    /// What stopping the menu bar app did.
    public enum AppStop: Equatable {
        case stopped
        case notRunning
        /// The app may still be running; `message` says why, for a warning.
        case failed(String)
    }

    /// Stop the menu bar app and report what actually happened. killall's exit
    /// status isn't trusted: 1 means both "none found" and "couldn't signal it",
    /// and 0 doesn't prove the app quit. So the outcome comes from checking whether
    /// the app is still running afterward, allowing `waitLimit` for it to exit.
    /// Gone: `.stopped` if it was running before, `.notRunning` if it wasn't. Still
    /// there, or no answer: `.failed`, carrying killall's own text.
    public static func stopApp(isRunning: () -> Bool?,
                               kill: () -> ToolRun,
                               waitLimit: TimeInterval = 3,
                               pollInterval: TimeInterval = 0.1,
                               sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> AppStop {
        let before = isRunning()
        let killRun = kill()
        var after = isRunning()
        var waited: TimeInterval = 0
        while after != false && waited < waitLimit {
            sleep(pollInterval)
            waited += pollInterval
            after = isRunning()
        }

        let killDetail: String
        switch killRun {
        case .exited(let status, let output):
            killDetail = exitDetail(tool: "killall", status: status, output: output)
        case .notLaunched(let reason):
            killDetail = "killall didn't run: \(reason)"
        }

        switch after {
        case false?:
            // Unknown beforehand: killall signalling something is the best hint.
            let signalled: Bool
            if case .exited(0, _) = killRun { signalled = true } else { signalled = false }
            return (before ?? signalled) ? .stopped : .notRunning
        case true?:
            return .failed("the menu bar app is still running (\(killDetail))")
        case nil:
            return .failed("couldn't confirm the menu bar app stopped (\(killDetail))")
        }
    }
}
