//
//  Daemon.swift
//  ThermalForge
//
//  Privileged daemon that runs as root via launchd.
//  Listens on a Unix socket so the app can control fans without sudo.
//

import Darwin
import Foundation
import IOKit.pwr_mgt

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

        // Bounded connect: a wedged daemon (accept loop stalled, listen backlog
        // full) must make this return false — NOT hang. This is on the emergency
        // reset path: `sudo thermalforge auto` → FanCommandRouter.apply → this
        // guard; returning false there falls back to a direct root SMC reset, which
        // is exactly the right behavior when the daemon can't be reached. An
        // unbounded connect here would hang the one command that must always work.
        return connectWithTimeout(fd, &addr, timeout: 2.0)
    }

    /// Whether launchd has our label registered in the system domain. This is
    /// true even when the job is loaded-but-failing (retry-looping on a dead
    /// exec) — where `isRunning` is false because the socket never comes up — so
    /// it's the right question to ask before deciding to boot out. Requires root
    /// (system domain); the install/uninstall callers already run under sudo.
    public static var isRegisteredWithLaunchd: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "system/\(label)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Boot out our launchd job, but only if the label is actually registered —
    /// so a fresh install (nothing loaded) doesn't provoke a spurious
    /// "Boot-out failed: No such process". If a bootout IS attempted and fails
    /// for a real reason, it throws rather than swallowing it.
    public static func bootoutIfRegistered() throws {
        guard isRegisteredWithLaunchd else { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "system/\(label)"]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ThermalForgeError.writeFailed(
                "launchctl bootout system/\(label) failed (exit \(p.terminationStatus))"
            )
        }
        Thread.sleep(forTimeInterval: 0.5)   // let launchd settle before re-bootstrap
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

/// The daemon's current hold, returned by the `state` verb as JSON.
public struct DaemonHoldState: Codable, Equatable {
    /// The held fan command ("max", "set 3000", "setfan 1 3000"), or nil if none.
    public let command: String?
    /// Who set it: "cli" (unsupervised, never watchdog-reverted), "app"
    /// (supervised, reverted if the app stops checking in), or "none".
    public let owner: String

    public init(command: String?, owner: String) {
        self.command = command
        self.owner = owner
    }

    public var isEmpty: Bool { owner == "none" }
    public var isCLIHold: Bool { owner == "cli" }
}

public final class DaemonClient {
    public init() {}

    /// Read the daemon's current hold (what's set and who owns it) so the menu
    /// bar app can reflect a CLI hold instead of fighting or wiping it.
    public func readState() throws -> DaemonHoldState {
        let reply = try send("state")
        guard let data = reply.data(using: .utf8),
              let state = try? JSONDecoder().decode(DaemonHoldState.self, from: data)
        else { throw DaemonError.commandFailed("malformed state response") }
        return state
    }

    /// Send a command to the daemon and return the response, throwing
    /// `commandFailed` on an "error:" reply. Use this when an error reply means
    /// the command genuinely failed.
    public func send(_ command: String) throws -> String {
        let response = try sendRaw(command)
        if response.hasPrefix("error:") {
            throw DaemonError.commandFailed(
                String(response.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            )
        }
        return response
    }

    /// Send a command and return the raw response WITHOUT throwing on an
    /// "error:" reply. Needed for version reconciliation: a daemon that predates
    /// the `version` command replies with the literal string
    /// "error: unknown command 'version'" (a normal response, not a dropped
    /// connection), and the caller must see that string to recognize the daemon
    /// as stale rather than mistake the error text for a version number.
    public func sendRaw(_ command: String, timeout: TimeInterval = 2.0) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.connectionFailed }
        defer { close(fd) }

        // Bound every send/recv so a hung or contended daemon can never block the
        // caller indefinitely — the v0.1.7 freeze. Healthy round-trips here are
        // sub-millisecond (heartbeat/version/state) to low-single-digit ms; 2s is
        // a stall cutoff with ~100x margin over the heaviest real reply. A caller
        // sending a heavier verb can raise it.
        let whole = Int(timeout)
        var tv = timeval(tv_sec: whole, tv_usec: Int32((timeout - Double(whole)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        setPath(&addr, ThermalForgeDaemon.socketPath)

        // connect() must ALSO be bounded, not just read/write. A wedged daemon
        // (accept loop stalled in a slow handleClient, listen backlog full) makes a
        // fresh connect() block indefinitely — and with the launch-adopt gate that
        // would silently leave the app with no fan control and no heartbeat. The
        // shared helper connects non-blocking, polls within `timeout`, and restores
        // blocking mode on success so SO_RCVTIMEO/SO_SNDTIMEO govern the read/write.
        guard connectWithTimeout(fd, &addr, timeout: timeout) else {
            throw DaemonError.notRunning
        }

        // Send command
        let cmdData = Array((command + "\n").utf8)
        _ = cmdData.withUnsafeBufferPointer { buf in
            write(fd, buf.baseAddress!, buf.count)
        }

        // Read response — 8KB handles status JSON on sensor-rich machines
        var buffer = [UInt8](repeating: 0, count: 8192)
        let n = read(fd, &buffer, buffer.count - 1)
        guard n > 0 else { throw DaemonError.connectionFailed }

        return String(bytes: buffer[0..<n], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Send a FanCommand to the daemon.
    /// - oneshot: append the `oneshot` token so the daemon applies the command
    ///   but does NOT arm its heartbeat watchdog — for fire-and-forget CLI holds
    ///   that must persist without a supervising process. The menu bar app leaves
    ///   this false so it stays supervised/crash-protected. No effect on
    ///   resetAuto (nothing to hold).
    public func execute(_ command: FanCommand, oneshot: Bool = false) throws {
        let token = (oneshot && command.isHold) ? " oneshot" : ""
        let cmdString: String
        switch command {
        case .setMax: cmdString = "max" + token
        case .setRPM(let rpm): cmdString = "set \(Int(rpm))" + token
        case .setFan(let index, let rpm): cmdString = "setfan \(index) \(Int(rpm))" + token
        case .resetAuto: cmdString = "auto"
        }
        _ = try send(cmdString)
    }
}

// MARK: - Hold State

/// The daemon's current fan hold. Distinguishes an unsupervised CLI hold (never
/// watchdog-reverted — a fire-and-forget `thermalforge max`) from a supervised
/// app hold (reverted if the app stops checking in). These are the two states
/// the old single `lastHeartbeat: Date?` nil conflated, which is why an app
/// heartbeat silently re-armed the watchdog against a CLI oneshot hold (v0.1.5).
private enum HoldState {
    case none
    case unsupervised(command: String)
    case supervised(command: String, lastBeat: Date)

    /// The held command string ("max" / "set 3000" / "setfan 1 3000"), for
    /// wake re-apply. nil when nothing is held.
    var command: String? {
        switch self {
        case .none: return nil
        case .unsupervised(let c), .supervised(let c, _): return c
        }
    }

    var snapshot: DaemonHoldState {
        switch self {
        case .none: return DaemonHoldState(command: nil, owner: "none")
        case .unsupervised(let c): return DaemonHoldState(command: c, owner: "cli")
        case .supervised(let c, _): return DaemonHoldState(command: c, owner: "app")
        }
    }
}

// MARK: - Daemon Server

public final class DaemonServer {
    private let socketFD: Int32
    private let fanControl: FanControl
    /// Serializes all SMC access — prevents data race between client handler and watchdog
    private let smcLock = NSLock()
    /// The current hold and its owner. Re-applied after sleep/wake; the watchdog
    /// reverts it only when it's `.supervised` and the app has gone silent.
    private var hold: HoldState = .none
    private let stateLock = NSLock()

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

        // Watch for sleep/wake to re-apply fan settings
        registerWakeNotification()

        // Heartbeat watchdog: if app set fans to manual but hasn't checked in
        // for 15 seconds, reset to auto. Prevents fans stuck after app crash.
        startHeartbeatWatchdog()

        // Accept connections on a background thread
        // (RunLoop.main needed for NSWorkspace notifications)
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let clientFD = accept(socketFD, nil, nil)
                guard clientFD >= 0 else { continue }
                // Drain per-connection autoreleased temporaries. This GCD block
                // never returns, so without an explicit pool anything autoreleased
                // inside handleClient would accumulate for the daemon's lifetime.
                // accept() and the guard stay OUTSIDE the pool so `continue` keeps
                // its normal loop meaning (no return-scope subtlety).
                autoreleasepool {
                    handleClient(clientFD)
                    close(clientFD)
                }
            }
        }

        // Main thread runs the RunLoop for wake notifications
        RunLoop.main.run()
    }

    // MARK: - Heartbeat Watchdog

    private func startHeartbeatWatchdog() {
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                Thread.sleep(forTimeInterval: 5)

                stateLock.lock()
                let current = hold
                stateLock.unlock()

                // ONLY a supervised hold is reverted — that's the app's crash
                // protection: the app set fans manually and stopped checking in,
                // so hand control back to macOS. An unsupervised CLI hold is
                // never touched here (the user asked for it; it persists until
                // CLI `auto` or the menu bar Default clears it). This is the
                // v0.1.5 fix: the app's heartbeat can no longer drag a CLI hold
                // into the supervised branch.
                guard case .supervised(_, let lastBeat) = current,
                      Date().timeIntervalSince(lastBeat) > 15 else { continue }

                // Only the revert path allocates anything autoreleasable (NSLog +
                // error interpolation), and it never returns from this loop, so pool
                // it. The sleep/guard/continue stay outside — a steady tick allocates
                // nothing autoreleasable (Date is a value type).
                autoreleasepool {
                    NSLog("ThermalForge daemon: heartbeat timeout — resetting fans to auto")
                    smcLock.lock()
                    let resetSucceeded: Bool
                    do {
                        try fanControl.resetAuto()
                        resetSucceeded = true
                    } catch {
                        NSLog("ThermalForge daemon: watchdog reset failed: %@, will retry", "\(error)")
                        resetSucceeded = false
                    }
                    smcLock.unlock()

                    // Clear only if the reset worked AND the same supervised hold is
                    // still current — a new command may have arrived meanwhile.
                    if resetSucceeded {
                        stateLock.lock()
                        if case .supervised(_, let beat) = hold, beat == lastBeat { hold = .none }
                        stateLock.unlock()
                    }
                }
            }
        }
    }

    // MARK: - Sleep/Wake

    /// IOKit root port for power notifications
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    private func registerWakeNotification() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(
            refcon, &notifyPort, { (refcon, _, messageType, messageArgument) in
                guard let refcon = refcon else { return }
                let server = Unmanaged<DaemonServer>.fromOpaque(refcon).takeUnretainedValue()

                // IOKit message constants (macros unavailable in Swift)
                let kSystemHasPoweredOn: UInt32 = 0xe0000300
                let kSystemWillSleep: UInt32 = 0xe0000280
                let kCanSystemSleep: UInt32 = 0xe0000270

                switch messageType {
                case kSystemHasPoweredOn:
                    server.handleWake()
                case kSystemWillSleep, kCanSystemSleep:
                    IOAllowPowerChange(server.rootPort, numericCast(Int(bitPattern: messageArgument)))
                default:
                    break
                }
            }, &notifier
        )

        guard rootPort != 0, let notifyPort = notifyPort else {
            NSLog("ThermalForge daemon: failed to register for power notifications")
            return
        }

        let source = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        NSLog("ThermalForge daemon: registered for wake notifications")
    }

    private func handleWake() {
        stateLock.lock()
        let heldCommand = hold.command
        stateLock.unlock()
        guard let command = heldCommand else {
            NSLog("ThermalForge daemon: woke — no profile to re-apply")
            return
        }

        NSLog("ThermalForge daemon: woke — re-applying: %@", command)

        // Delay slightly — SMC needs a moment after wake
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) { [self] in
            smcLock.lock()
            defer { smcLock.unlock() }
            let parts = command.split(separator: " ")
            do {
                switch parts.first.map(String.init) {
                case "max":
                    try fanControl.setMax()
                case "set":
                    if let rpm = parts.dropFirst().first.flatMap({ Float($0) }) {
                        try fanControl.setAllFans(rpm: rpm)
                    }
                case "setfan":
                    let args = Array(parts.dropFirst())
                    if args.count >= 2, let index = Int(args[0]), let rpm = Float(args[1]) {
                        try fanControl.setSpeed(fan: index, rpm: rpm)
                    }
                default:
                    break
                }
                NSLog("ThermalForge daemon: re-applied after wake")
            } catch {
                NSLog("ThermalForge daemon: wake re-apply failed: %@", "\(error)")
            }
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
        smcLock.lock()
        defer { smcLock.unlock() }
        do {
            let parts = command.split(separator: " ")
            // `oneshot` token (0.1.5+): apply the command but leave the watchdog
            // disarmed, so a fire-and-forget CLI hold persists instead of being
            // reverted after 15s. Old daemons never see this branch — they just
            // ignore the trailing token.
            let oneshot = parts.contains("oneshot")

            // Record a hold: unsupervised (CLI oneshot — never watchdog-reverted)
            // or supervised (app — reverted if it stops checking in). Overwrites
            // whatever was held, so an explicit app command cleanly takes over a
            // CLI hold with no orphan left behind.
            func recordHold(_ heldCommand: String) {
                stateLock.lock()
                hold = oneshot
                    ? .unsupervised(command: heldCommand)
                    : .supervised(command: heldCommand, lastBeat: Date())
                stateLock.unlock()
            }

            // A supervised (app) command must NOT silently overwrite an
            // unsupervised CLI hold — the CLI hold wins and the app is told to
            // yield via the error, instead of clobbering it in the ~100ms before
            // its next state poll. `oneshot` commands and `auto` are never
            // blocked, so explicit app takeover (which sends `auto` first,
            // clearing the hold) still works. Checked before any SMC write.
            func blockedByCLIHold() -> Bool {
                guard !oneshot else { return false }
                stateLock.lock(); defer { stateLock.unlock() }
                if case .unsupervised = hold { return true }
                return false
            }

            switch parts.first.map(String.init) {
            case "max":
                if blockedByCLIHold() { response = "error: held by cli"; break }
                try fanControl.setMax()
                recordHold("max")
                response = "ok"
            case "auto":
                try fanControl.resetAuto()
                stateLock.lock(); hold = .none; stateLock.unlock()
                response = "ok"
            case "set":
                guard parts.count >= 2, let rpm = Float(parts[1]) else {
                    response = "error: usage: set <rpm>"
                    break
                }
                if blockedByCLIHold() { response = "error: held by cli"; break }
                try fanControl.setAllFans(rpm: rpm)
                recordHold("set \(Int(rpm))")
                response = "ok"
            case "setfan":
                guard parts.count >= 3, let index = Int(parts[1]), let rpm = Float(parts[2]) else {
                    response = "error: usage: setfan <index> <rpm>"
                    break
                }
                if blockedByCLIHold() { response = "error: held by cli"; break }
                try fanControl.setSpeed(fan: index, rpm: rpm)
                recordHold("setfan \(index) \(Int(rpm))")
                response = "ok"
            case "status":
                let status = try fanControl.status()
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                let data = try encoder.encode(status)
                response = String(data: data, encoding: .utf8) ?? "error: encode failed"
            case "state":
                // Current hold + owner as JSON, so the app can reflect a CLI hold
                // rather than fight or wipe it.
                stateLock.lock()
                let snap = hold.snapshot
                stateLock.unlock()
                if let data = try? JSONEncoder().encode(snap),
                   let json = String(data: data, encoding: .utf8) {
                    response = json
                } else {
                    response = "error: state encode failed"
                }
            case "heartbeat":
                // Refreshes a SUPERVISED hold's liveness only. On an unsupervised
                // CLI hold this is deliberately a no-op — the app checking in must
                // NOT convert a CLI hold into a supervised one (the v0.1.5 bug).
                stateLock.lock()
                if case .supervised(let c, _) = hold {
                    hold = .supervised(command: c, lastBeat: Date())
                }
                stateLock.unlock()
                response = "ok"
            case "version":
                // Reports the build this daemon process is running, so a CLI from
                // a newer install can detect it's talking to a stale daemon.
                response = ThermalForgeVersion.current
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

/// Connect `fd` to `addr` bounded by `timeout` seconds, so a wedged daemon (accept
/// loop stalled, listen backlog full) can never block the caller forever. Both
/// `DaemonClient.sendRaw` (throws on false) and `ThermalForgeDaemon.isRunning`
/// (returns the Bool) go through here, so the two connect paths can't diverge.
///
/// Non-blocking connect, then `poll()` for completion. `poll()` is retried on EINTR
/// with the REMAINING budget — a signal must not turn a healthy daemon into a
/// spurious "not running". On success the socket is restored to blocking mode so
/// any SO_RCVTIMEO/SO_SNDTIMEO the caller set still governs the following read/write.
private func connectWithTimeout(_ fd: Int32, _ addr: inout sockaddr_un, timeout: TimeInterval) -> Bool {
    let origFlags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, origFlags | O_NONBLOCK)

    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    var connected: Bool
    if rc == 0 {
        connected = true
    } else if errno == EINPROGRESS {
        connected = false
        let deadline = DispatchTime.now() + timeout
        while true {
            let now = DispatchTime.now()
            if now >= deadline { break }   // budget exhausted → not connected
            let remainingMs = Int32((deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000)

            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let por = poll(&pfd, 1, remainingMs)
            if por > 0 {
                // Woke on writability: connect finished — success iff SO_ERROR == 0.
                var soErr: Int32 = 0
                var soLen = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &soLen)
                connected = (soErr == 0)
                break
            } else if por == 0 {
                break                       // timed out → not connected
            } else if errno == EINTR {
                continue                    // interrupted — recompute remaining budget, retry
            } else {
                break                       // real poll error → not connected
            }
        }
    } else {
        connected = false                   // ECONNREFUSED, EAGAIN (backlog full), …
    }

    if connected { _ = fcntl(fd, F_SETFL, origFlags) }   // restore blocking for read/write
    return connected
}
