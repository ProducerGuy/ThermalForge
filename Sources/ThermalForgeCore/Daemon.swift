//
//  Daemon.swift
//  ThermalForge
//
//  Privileged daemon that runs as root via launchd.
//  Listens on a Unix socket so the app can control fans without sudo.
//

import Darwin
import Foundation

// MARK: - Constants

public enum ThermalForgeDaemon {
    public static let socketPath = "/tmp/thermalforge.sock"
    public static let plistPath = "/Library/LaunchDaemons/com.thermalforge.daemon.plist"
    public static let installPath = "/usr/local/bin/thermalforge"
    public static let label = "com.thermalforge.daemon"

    /// Check if the daemon socket exists and accepts connections
    public static var isRunning: Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        setPath(&addr, socketPath)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }
}

// MARK: - Daemon Client

public enum DaemonError: Error, CustomStringConvertible {
    case notRunning
    case connectionFailed
    case commandFailed(String)

    public var description: String {
        switch self {
        case .notRunning:
            return "ThermalForge daemon is not running. Run: sudo thermalforge install"
        case .connectionFailed:
            return "Failed to connect to daemon socket"
        case .commandFailed(let msg):
            return "Daemon error: \(msg)"
        }
    }
}

public final class DaemonClient {
    public init() {}

    /// Send a command to the daemon and return the response
    public func send(_ command: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.connectionFailed }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        setPath(&addr, ThermalForgeDaemon.socketPath)

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw DaemonError.notRunning }

        // Send command
        let cmdData = Array((command + "\n").utf8)
        _ = cmdData.withUnsafeBufferPointer { buf in
            write(fd, buf.baseAddress!, buf.count)
        }

        // Read response
        var buffer = [UInt8](repeating: 0, count: 1024)
        let n = read(fd, &buffer, buffer.count - 1)
        guard n > 0 else { throw DaemonError.connectionFailed }

        let response = String(bytes: buffer[0..<n], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if response.hasPrefix("error:") {
            throw DaemonError.commandFailed(
                String(response.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            )
        }

        return response
    }

    /// Send a FanCommand to the daemon
    public func execute(_ command: FanCommand) throws {
        let cmdString: String
        switch command {
        case .setMax: cmdString = "max"
        case .setRPM(let rpm): cmdString = "set \(Int(rpm))"
        case .resetAuto: cmdString = "auto"
        }
        _ = try send(cmdString)
    }
}

// MARK: - Daemon Server

public final class DaemonServer {
    private let socketFD: Int32
    private let fanControl: FanControl

    public init(fanControl: FanControl) throws {
        self.fanControl = fanControl

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ThermalForgeError.smcConnectionFailed
        }
        self.socketFD = fd

        // Remove stale socket
        unlink(ThermalForgeDaemon.socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        setPath(&addr, ThermalForgeDaemon.socketPath)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw ThermalForgeError.writeFailed("bind() failed: \(errno)")
        }

        // Allow all local users to connect
        chmod(ThermalForgeDaemon.socketPath, 0o777)

        guard listen(fd, 5) == 0 else {
            close(fd)
            throw ThermalForgeError.writeFailed("listen() failed")
        }
    }

    /// Run the server loop (blocks forever)
    public func run() {
        NSLog("ThermalForge daemon: listening on %@", ThermalForgeDaemon.socketPath)

        while true {
            let clientFD = accept(socketFD, nil, nil)
            guard clientFD >= 0 else { continue }
            handleClient(clientFD)
            close(clientFD)
        }
    }

    private func handleClient(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buffer, buffer.count - 1)
        guard n > 0 else { return }

        let command = String(bytes: buffer[0..<n], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        NSLog("ThermalForge daemon: received: %@", command)

        let response: String
        do {
            let parts = command.split(separator: " ")
            switch parts.first.map(String.init) {
            case "max":
                try fanControl.setMax()
                response = "ok"
            case "auto":
                try fanControl.resetAuto()
                response = "ok"
            case "set":
                guard parts.count >= 2, let rpm = Float(parts[1]) else {
                    response = "error: usage: set <rpm>"
                    break
                }
                try fanControl.setAllFans(rpm: rpm)
                response = "ok"
            case "status":
                let status = try fanControl.status()
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                let data = try encoder.encode(status)
                response = String(data: data, encoding: .utf8) ?? "error: encode failed"
            default:
                response = "error: unknown command '\(command)'"
            }
        } catch {
            response = "error: \(error)"
        }

        let responseBytes = Array((response + "\n").utf8)
        _ = responseBytes.withUnsafeBufferPointer { buf in
            write(fd, buf.baseAddress!, buf.count)
        }
    }

    deinit {
        close(socketFD)
        unlink(ThermalForgeDaemon.socketPath)
    }
}

// MARK: - Helpers

/// Copy a path string into sockaddr_un.sun_path
private func setPath(_ addr: inout sockaddr_un, _ path: String) {
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
            _ = strlcpy(dest, path, 104)
        }
    }
}
