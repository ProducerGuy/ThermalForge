//
//  PrivilegedExecutor.swift
//  ThermalForge
//
//  Executes fan control commands with admin privileges via the CLI binary.
//

import Foundation
import ThermalForgeCore

final class PrivilegedExecutor {
    /// Path to the thermalforge CLI binary
    private var cliPath: String {
        // In SPM builds, both binaries are in the same directory
        let myDir = Bundle.main.executableURL?
            .deletingLastPathComponent().path ?? "."
        let candidate = "\(myDir)/thermalforge"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Fallback: check common install locations
        for path in ["/usr/local/bin/thermalforge", "/opt/homebrew/bin/thermalforge"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return candidate
    }

    func execute(_ command: FanCommand) throws {
        let args: String
        switch command {
        case .setMax:
            args = "max"
        case .setRPM(let rpm):
            args = "set \(Int(rpm))"
        case .resetAuto:
            args = "auto"
        }

        let script = """
            do shell script "\(cliPath) \(args)" with administrator privileges
            """

        var error: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        appleScript?.executeAndReturnError(&error)

        if let error = error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            throw PrivilegedExecutorError.scriptFailed(message)
        }
    }
}

enum PrivilegedExecutorError: Error, CustomStringConvertible {
    case scriptFailed(String)

    var description: String {
        switch self {
        case .scriptFailed(let msg): return "Privileged execution failed: \(msg)"
        }
    }
}
