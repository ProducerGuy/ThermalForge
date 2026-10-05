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
    // /var/run is root-owned 0755: unprivileged processes cannot create entries,
    // so path squatting is structurally impossible (unlike world-writable /tmp).
    // Cleared at boot; RunAtLoad re-creates the socket at daemon load.
    public static let socketPath = "/var/run/thermalforge.sock"
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
    /// "Boot-out failed: No such process". Returns once launchd reports the job
    /// gone, not after a guessed delay. Failures throw a LaunchdError carrying
    /// `rerun`, the command that recovers.
    public static func bootoutIfRegistered(rerun: String) throws {
        try LaunchdControl.system.bootoutIfRegistered(label: label, rerun: rerun)
    }

    /// Load our launchd job, retrying once if the first attempt fails while
    /// nothing is registered. `note` receives a line for the user on a retry.
    public static func bootstrap(rerun: String, note: (String) -> Void = { _ in }) throws {
        try LaunchdControl.system.bootstrap(plist: plistPath, rerun: rerun, note: note)
    }

    /// Wait (bounded) for the daemon's socket to accept connections, instead of
    /// checking once after a fixed delay. False only if `limit` passes first.
    public static func waitUntilRunning(limit: TimeInterval = 10) -> Bool {
        LaunchdControl.system.waitUntil(limit: limit) { isRunning }
    }

    /// Where the daemon's file log lived before it moved to the unified log:
    /// TFLogger wrote under the running user's home, and the daemon runs as root.
    /// Nothing writes it anymore: as root, TFLogger logs to the unified log only.
    public static let legacyLogDirectory = "/var/root/Library/Logs/ThermalForge"

    public enum LegacyLogCleanup: Equatable {
        case notPresent
        case removed
        case failed(String)
    }

    /// Remove the old daemon log folder at exactly `path`, never anything outside
    /// it: a symlink at `path` is removed as a link, and links inside are removed
    /// as links, not followed.
    public static func removeLegacyLogs(at path: String = legacyLogDirectory) -> LegacyLogCleanup {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let err = errno
            return err == ENOENT ? .notPresent : .failed("\(String(cString: strerror(err))) (errno \(err))")
        }
        do {
            try FileManager.default.removeItem(atPath: path)
            return .removed
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// A launchd step that failed during install or uninstall. Kept apart from
/// ThermalForgeError, whose cases describe SMC failures: a bootout/bootstrap
/// problem is neither an SMC write nor fixed by sudo (the caller already has it),
/// and the user needs the command that recovers. `detail` is launchctl's own
/// output, folded in so the user sees one message with the real cause.
public enum LaunchdError: Error, CustomStringConvertible, Equatable {
    case bootoutFailed(exitStatus: Int32, detail: String, rerun: String)
    case stillRegistered(seconds: Int, rerun: String)
    case bootstrapFailed(exitStatus: Int32, detail: String, rerun: String)

    public var description: String {
        switch self {
        case .bootoutFailed(let status, let detail, let rerun):
            return "Couldn't stop the running ThermalForge daemon\(Self.cause(detail, status)). Re-run: \(rerun)"
        case .stillRegistered(let seconds, let rerun):
            return "launchd still had the old ThermalForge daemon registered \(seconds)s after it was stopped. Re-run: \(rerun)"
        case .bootstrapFailed(let status, let detail, let rerun):
            return "Couldn't start the ThermalForge daemon, also on retry\(Self.cause(detail, status)). Re-run: \(rerun)"
        }
    }

    /// ": <launchctl's message> (launchctl exit N)", or just the exit status when
    /// launchctl said nothing.
    static func cause(_ detail: String, _ status: Int32) -> String {
        detail.isEmpty ? " (launchctl exit \(status))" : ": \(detail) (launchctl exit \(status))"
    }
}

/// Why the daemon couldn't start serving. Kept apart from ThermalForgeError, whose
/// cases describe SMC failures: none of these is an SMC write, and the daemon
/// already runs as root, so "run with sudo" is never the fix.
public enum DaemonStartError: Error, CustomStringConvertible, Equatable {
    case ownerIsRoot
    case socketFailed(errno: Int32)
    case bindFailed(path: String, errno: Int32)
    case chownFailed(path: String, uid: uid_t, errno: Int32)
    case chmodFailed(path: String, errno: Int32)
    case listenFailed(errno: Int32)

    public var description: String {
        switch self {
        case .ownerIsRoot:
            return "refusing to start: the owner uid is 0. Reinstall from your user account: sudo thermalforge install"
        case .socketFailed(let err):
            return "couldn't create the control socket: \(Self.reason(err))"
        case .bindFailed(let path, let err):
            return "couldn't bind the control socket at \(path): \(Self.reason(err))"
        case .chownFailed(let path, let uid, let err):
            return "couldn't give the control socket at \(path) to uid \(uid): \(Self.reason(err))"
        case .chmodFailed(let path, let err):
            return "couldn't set the control socket at \(path) to mode 0600: \(Self.reason(err))"
        case .listenFailed(let err):
            return "couldn't listen on the control socket: \(Self.reason(err))"
        }
    }

    private static func reason(_ err: Int32) -> String {
        "\(String(cString: strerror(err))) (errno \(err))"
    }
}

/// The launchd steps install/uninstall drive. launchctl, the registration query
/// and the clock are injected so the ordering logic tests without root; `system`
/// is the real thing. Nothing here waits a fixed time: each wait polls for the
/// state it needs, bounded so a genuine failure still ends.
struct LaunchdControl {
    /// Runs launchctl with the given arguments; returns its exit status and its
    /// combined stdout/stderr, trimmed. Output is captured, never printed raw.
    var launchctl: ([String]) throws -> (status: Int32, output: String)
    var isRegistered: () -> Bool
    var now: () -> Date = Date.init
    var pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    /// Cap on waiting for launchd to finish tearing the old job down. Above
    /// launchd's default 20s SIGTERM→SIGKILL exit timeout, so it only ends a wait
    /// that is never going to succeed.
    var teardownLimit: TimeInterval = 30
    var pollInterval: TimeInterval = 0.2

    static let system = LaunchdControl(
        launchctl: { arguments in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = arguments
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try p.run()
            // Drain before waiting, so a full pipe can never stall launchctl.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (p.terminationStatus, output)
        },
        isRegistered: { ThermalForgeDaemon.isRegisteredWithLaunchd }
    )

    /// Poll `condition` until it holds; false only if `limit` passes first.
    func waitUntil(limit: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = now().addingTimeInterval(limit)
        while true {
            if condition() { return true }
            if now() >= deadline { return false }
            pause(pollInterval)
        }
    }

    func bootoutIfRegistered(label: String, rerun: String) throws {
        guard isRegistered() else { return }
        let result = try launchctl(["bootout", "system/\(label)"])
        guard result.status == 0 else {
            throw LaunchdError.bootoutFailed(exitStatus: result.status, detail: result.output, rerun: rerun)
        }
        // bootout can return before launchd finishes tearing the job down; an
        // immediate bootstrap would then fail. Wait for the state, not a delay.
        guard waitUntil(limit: teardownLimit, { !isRegistered() }) else {
            throw LaunchdError.stillRegistered(seconds: Int(teardownLimit), rerun: rerun)
        }
    }

    func bootstrap(plist: String, rerun: String, note: (String) -> Void) throws {
        let first = try launchctl(["bootstrap", "system", plist])
        guard first.status != 0 else { return }
        // Registered despite the error: the job is loaded, so the caller's
        // running check decides. Retrying would only fail on the existing job.
        guard !isRegistered() else { return }
        note("Starting the daemon failed\(LaunchdError.cause(first.output, first.status)); retrying once.")
        let second = try launchctl(["bootstrap", "system", plist])
        guard second.status == 0 else {
            throw LaunchdError.bootstrapFailed(exitStatus: second.status, detail: second.output, rerun: rerun)
        }
    }
}

// MARK: - Daemon Client

public enum DaemonError: Error, CustomStringConvertible {
    case notRunning
    case connectionFailed
    case commandFailed(String)
    /// The running daemon speaks the pre-Phase-2 string protocol (upgrade window:
    /// `brew upgrade` done, `sudo thermalforge install` not yet). Its socket is up so
    /// it isn't "not running" — callers must handle this distinctly (reinstall nudge /
    /// direct-SMC fallback), not mistake it for a transient failure.
    case incompatibleDaemon

    public var description: String {
        switch self {
        case .notRunning:
            return "ThermalForge daemon is not running. Run: sudo thermalforge install"
        case .connectionFailed:
            return "Failed to connect to daemon socket"
        case .commandFailed(let msg):
            return "Daemon error: \(msg)"
        case .incompatibleDaemon:
            return "The background daemon is an older build using the previous control protocol. Reinstall to reconnect: sudo thermalforge install"
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
    /// True while the thermal floor is overriding this hold to max for safety. The
    /// `command` still reflects what the USER asked for (e.g. "set 2000"), never "max",
    /// so the app can say "held at 2000 — temporarily maxed for safety".
    public let safetySuspended: Bool

    public init(command: String?, owner: String, safetySuspended: Bool = false) {
        self.command = command
        self.owner = owner
        self.safetySuspended = safetySuspended
    }

    public var isEmpty: Bool { owner == "none" }
    public var isCLIHold: Bool { owner == "cli" }
}

/// The result of applying a fan command: the daemon's advisory note (e.g. a clamp)
/// and the RPM it actually applied. Both come straight from the daemon's response so
/// the CLI echoes the authoritative value, never a laggy target-register read-back.
public struct FanApplyResult: Equatable {
    public let note: String?
    public let appliedRPM: Int?
    public init(note: String?, appliedRPM: Int?) {
        self.note = note
        self.appliedRPM = appliedRPM
    }
}

public final class DaemonClient {
    private let socketPath: String

    public init() { self.socketPath = ThermalForgeDaemon.socketPath }

    /// Test seam: point the client at a plain bound AF_UNIX socket instead of the
    /// daemon's. Production callers use `init()`.
    init(socketPath: String) { self.socketPath = socketPath }

    /// Read the daemon's current hold (what's set and who owns it) so the menu
    /// bar app can reflect a CLI hold instead of fighting or wiping it.
    public func readState() throws -> DaemonHoldState {
        let response = try request(DaemonRequest(verb: .state))
        guard response.ok, let state = response.state else {
            throw DaemonError.commandFailed("malformed state response")
        }
        return state
    }

    /// Apply a `FanCommand`, throwing `commandFailed` on an error response.
    /// - oneshot: apply the command but do NOT arm the heartbeat watchdog — for
    ///   fire-and-forget CLI holds that must persist without a supervising process.
    ///   The menu bar app leaves this false so it stays supervised/crash-protected.
    ///   No effect on resetAuto (nothing to hold).
    @discardableResult
    public func execute(_ command: FanCommand, oneshot: Bool = false) throws -> FanApplyResult {
        let response = try request(DaemonRequest(command, oneshot: oneshot))
        guard response.ok else {
            throw DaemonError.commandFailed(
                response.message ?? response.error.map { String(describing: $0) } ?? "daemon error"
            )
        }
        // Note + applied RPM ride back on an OK response (e.g. a clamp).
        return FanApplyResult(note: response.note, appliedRPM: response.appliedRPM)
    }

    /// Send one typed request and return the typed response — length-prefixed JSON
    /// frames, no string protocol. Runs over the SAME bounded socket code as before
    /// (the v0.1.7 freeze fix): non-blocking `connectWithTimeout` plus
    /// SO_RCVTIMEO/SO_SNDTIMEO, so a wedged daemon can never block the caller.
    public func request(_ req: DaemonRequest, timeout: TimeInterval = 2.0) throws -> DaemonResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.connectionFailed }
        defer { close(fd) }

        // Bound every send/recv so a hung or contended daemon can never block the
        // caller indefinitely — the v0.1.7 freeze. Healthy round-trips here are
        // sub-millisecond (heartbeat/version/state) to low-single-digit ms; 2s is a
        // stall cutoff with wide margin over the heaviest real reply.
        let whole = Int(timeout)
        var tv = timeval(tv_sec: whole, tv_usec: Int32((timeout - Double(whole)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // A daemon that closes before replying (restart, or a rejected peer) must make
        // the write fail with EPIPE, not raise SIGPIPE and kill the app or CLI. Any new
        // client socket must set SO_NOSIGPIPE too.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        setPath(&addr, socketPath)

        // connect() must ALSO be bounded, not just read/write. A wedged daemon
        // (accept loop stalled in a slow handleClient, listen backlog full) makes a
        // fresh connect() block indefinitely — and with the launch-adopt gate that
        // would silently leave the app with no fan control and no heartbeat. The
        // shared helper connects non-blocking, polls within `timeout`, and restores
        // blocking mode on success so SO_RCVTIMEO/SO_SNDTIMEO govern the frame I/O.
        guard connectWithTimeout(fd, &addr, timeout: timeout) else {
            throw DaemonError.notRunning
        }

        let frame = try DaemonProtocol.encodeFrame(req, max: DaemonProtocol.maxRequestBytes)
        try DaemonProtocol.writeFrame(fd, frame)
        do {
            let body = try DaemonProtocol.readFrame(fd, max: DaemonProtocol.maxResponseBytes)
            return try DaemonProtocol.decode(DaemonResponse.self, from: body)
        } catch DaemonProtocol.FrameError.legacyPeer {
            // A pre-Phase-2 daemon replied with a raw string; surface it distinctly so
            // callers can nudge a reinstall / fall back to direct SMC, not treat it as
            // a generic failure.
            throw DaemonError.incompatibleDaemon
        }
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

    func snapshot(safetySuspended: Bool = false) -> DaemonHoldState {
        switch self {
        case .none: return DaemonHoldState(command: nil, owner: "none", safetySuspended: safetySuspended)
        case .unsupervised(let c): return DaemonHoldState(command: c, owner: "cli", safetySuspended: safetySuspended)
        case .supervised(let c, _): return DaemonHoldState(command: c, owner: "app", safetySuspended: safetySuspended)
        }
    }
}

// MARK: - Daemon Server

public final class DaemonServer {
    private let socketFD: Int32
    private let fanControl: FanControl
    /// uid of the controlling user (who ran `sudo thermalforge install`). The
    /// socket is chown'd to this uid + 0600, so only that user (and root) connect.
    private let ownerUID: uid_t
    /// Serializes all SMC access — prevents data race between client handler and watchdog
    private let smcLock = NSLock()
    /// The current hold and its owner. Re-applied after sleep/wake; the watchdog
    /// reverts it only when it's `.supervised` and the app has gone silent.
    private var hold: HoldState = .none
    /// True while the thermal floor is overriding a hold to max. Guarded by stateLock.
    private var safetySuspended = false
    private let stateLock = NSLock()

    /// Per-fan [min, max] RPM, cached at init (fixed hardware constants) for clamping
    /// `set`/`setfan` — so a hostile value can't drive the SMC out of range.
    private let fanLimits: [(min: Float, max: Float)]
    /// Flood protection for SMC-writing verbs (`auto`/reset exempt). Guarded by rateLock.
    private var rateLimiter: RateLimiter
    private let rateLock = NSLock()
    /// The thermal safety floor's decision logic (thresholds mirrored from FanProfile).
    private let thermalFloor = ThermalFloor()
    /// A temperature sampler injected by tests. When nil, the floor reads the SMC
    /// safety keys itself — per key under smcLock — so it unit-tests via ThermalFloor
    /// and runs without head-of-line blocking in production.
    private let injectedSampler: (() -> Float?)?

    /// Phase 4 connection layer (concurrent bounded accept + framed I/O), created in run().
    private var connectionServer: ConnectionServer?
    /// SIGTERM handler (#31), created in run(); kept so the source isn't released.
    private var terminationSource: DispatchSourceSignal?

    public init(fanControl: FanControl, ownerUID: uid_t,
                sampleMaxTemp: (() -> Float?)? = nil) throws {
        // First, before anything can log: the daemon's fan messages go to the
        // unified log with the daemon's own prefix.
        fanControl.logSink = { DaemonLog.notice("ThermalForge daemon: \($0)") }
        self.fanControl = fanControl
        self.ownerUID = ownerUID
        // Cache fan RPM limits once (fixed hardware constants). Empty on a read failure
        // → clamp becomes a no-op and FanControl's own range check stays the backstop.
        self.fanLimits = (try? fanControl.status())?.fans
            .map { (Float($0.minRPM), Float($0.maxRPM)) } ?? []
        self.rateLimiter = RateLimiter(now: Date())
        self.injectedSampler = sampleMaxTemp

        // Refuse to start with an unusable owner. uid 0 would make the socket
        // root-only and silently lock every non-root account (the user's app/CLI)
        // out of fan control. Fail loudly under KeepAlive so Console.app shows why,
        // rather than a mystery "daemon-down" banner. Install.run() guarantees a
        // real uid, so reaching here means a hand-edited plist or a dev mistake.
        guard ownerUID != 0 else { throw Self.startFailure(.ownerIsRoot) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.startFailure(.socketFailed(errno: errno)) }
        self.socketFD = fd

        // Remove stale socket (safe now: only root can have created anything in
        // root-owned /var/run — no unprivileged squatter to preserve).
        unlink(ThermalForgeDaemon.socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        setPath(&addr, ThermalForgeDaemon.socketPath)

        // Bind under a 0077 umask so the socket is 0700-from-birth — the previous
        // bind→chmod gap (default umask briefly left it world-accessible) never
        // exists. Restore the process umask immediately after.
        let oldMask = umask(0o077)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let bindErrno = errno   // captured before any other call can change it
        umask(oldMask)
        guard bindResult == 0 else {
            close(fd)
            throw Self.startFailure(.bindFailed(path: ThermalForgeDaemon.socketPath, errno: bindErrno))
        }

        // Hand the socket to the controlling user: owned by them, group wheel,
        // 0600. Only that user (and root — perms don't bind root) can connect.
        //
        // The boundary is the umask(0o077) above — the socket is 0700-from-birth
        // unconditionally. These two calls are refinement, not the boundary: chown so
        // the user (not just root) can connect, chmod to trim the meaningless execute
        // bit on a socket. Neither degrades security if it fails — chown failing
        // leaves it root-only (fails closed); chmod failing leaves user-owned 0700,
        // functionally identical to 0600 on a socket. We guard them anyway for
        // DIAGNOSABILITY: an unchecked failure would surface as a mystery
        // "daemon-down" banner with no cause. A loud crash-loop under KeepAlive that
        // puts the errno in Console.app beats a silent lockout.
        guard chown(ThermalForgeDaemon.socketPath, ownerUID, 0) == 0 else {
            let err = errno
            close(fd)
            throw Self.startFailure(.chownFailed(path: ThermalForgeDaemon.socketPath, uid: ownerUID, errno: err))
        }
        guard chmod(ThermalForgeDaemon.socketPath, 0o600) == 0 else {
            let err = errno
            close(fd)
            throw Self.startFailure(.chmodFailed(path: ThermalForgeDaemon.socketPath, errno: err))
        }

        guard listen(fd, 16) == 0 else {   // backlog holds queued connects while at the 8-handler cap
            let err = errno
            close(fd)
            throw Self.startFailure(.listenFailed(errno: err))
        }
    }

    /// Log a start failure where Console.app can read it (launchd discards the
    /// daemon's stderr), then hand it back to throw.
    private static func startFailure(_ error: DaemonStartError) -> DaemonStartError {
        DaemonLog.error("ThermalForge daemon: \(error)")
        return error
    }

    /// Run the server loop (blocks forever)
    public func run() {
        DaemonLog.notice("ThermalForge daemon: listening on \(ThermalForgeDaemon.socketPath)")

        // Start holding nothing with nothing pinned, before any client can connect
        // or any loop can act (#31): release fans a previous daemon or a direct
        // root write left under manual control.
        reconcileFansAtStartup()

        // Release our fans if we're told to stop (bootout, kill -TERM).
        installTerminationHandler()

        // Watch for sleep/wake to re-apply fan settings
        registerWakeNotification()

        // Heartbeat watchdog: if app set fans to manual but hasn't checked in
        // for 15 seconds, reset to auto. Prevents fans stuck after app crash.
        startHeartbeatWatchdog()

        // Thermal safety floor: overrides a below-max hold toward max when a critical
        // sensor crosses the threshold, unkillable from user space. Defense in depth —
        // the client monitor is primary; this is the backstop that survives the app.
        startThermalFloor()

        // Accept connections concurrently (bounded) so one hung connection can't stall
        // others, and — the security fix — a slow-reading client can no longer hold
        // smcLock during the response write (processFrame takes it only around process()).
        // Every accepted connection is checked against the peer's kernel credentials
        // (root or ownerUID only), a second layer behind the socket's 0600 permissions.
        let server = ConnectionServer(listenFD: socketFD,
                                      authorizer: PeerAuthorizer(ownerUID: ownerUID)) { [self] body in
            processFrame(body)
        }
        server.start()
        connectionServer = server

        // Main thread runs the RunLoop for wake notifications
        RunLoop.main.run()
    }

    // MARK: - Start and Stop (#31)

    private func reconcileFansAtStartup() {
        smcLock.lock()
        defer { smcLock.unlock() }
        switch StartupFanReconcile.run(manualControlEngaged: { try fanControl.manualControlEngaged() },
                                       resetAuto: { try fanControl.resetAuto() }) {
        case .alreadyAuto:
            break
        case .reset:
            DaemonLog.notice("ThermalForge daemon: fans were under manual control with no hold at startup; reset to auto")
        case .resetAfterUnreadable:
            DaemonLog.notice("ThermalForge daemon: couldn't read fan modes at startup; reset to auto as a precaution")
        case .resetFailed(let error):
            DaemonLog.error("ThermalForge daemon: startup fan reset failed: \(error)")
        }
    }

    /// SIGTERM's default action kills the daemon with whatever hold it had still
    /// on the SMC. A dispatch source runs our handler on a normal thread instead of
    /// in signal context, so taking locks and writing the SMC is safe there.
    private func installTerminationHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        source.setEventHandler { [self] in releaseFansAndExit() }
        source.resume()
        terminationSource = source
    }

    private func releaseFansAndExit() -> Never {
        // smcLock is held through exit, so no request, watchdog, floor or wake
        // re-apply can write the SMC after the release. Lock order matches
        // processFrame (smcLock, then stateLock).
        smcLock.lock()
        stateLock.lock()
        let release = DaemonShutdown.releasesFans(holding: hold.command != nil,
                                                  safetySuspended: safetySuspended)
        hold = .none
        safetySuspended = false
        stateLock.unlock()
        if release {
            let ok = (try? fanControl.resetAuto()) != nil
            DaemonLog.notice("ThermalForge daemon: stopping: \(ok ? "released fans to auto" : "fan release failed")")
        }
        exit(0)
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
                      HeartbeatWatchdog.revertsHold(lastBeat: lastBeat, now: Date()) else { continue }

                // The revert happens even while the thermal floor holds fans at max:
                // Apple's auto control is the safe default on a hot machine too. The
                // floor exists to correct a ThermalForge hold pinning fans low; once
                // the dead app's hold is gone there is nothing of ours to correct, so
                // the suspension is cleared with it (below).

                // Only the revert path allocates anything autoreleasable (logging +
                // error interpolation), and it never returns from this loop, so pool
                // it. The sleep/guard/continue stay outside — a steady tick allocates
                // nothing autoreleasable (Date is a value type).
                autoreleasepool {
                    DaemonLog.notice("ThermalForge daemon: heartbeat timeout; resetting fans to auto")
                    smcLock.lock()
                    let resetSucceeded: Bool
                    do {
                        try fanControl.resetAuto()
                        resetSucceeded = true
                    } catch {
                        DaemonLog.error("ThermalForge daemon: watchdog reset failed: \(error), will retry")
                        resetSucceeded = false
                    }
                    smcLock.unlock()

                    // Clear only if the reset worked AND the same supervised hold is
                    // still current — a new command may have arrived meanwhile. Apple
                    // now has the fans, so any floor override ends with the hold.
                    if resetSucceeded {
                        stateLock.lock()
                        if case .supervised(_, let beat) = hold, beat == lastBeat {
                            hold = .none
                            safetySuspended = false
                        }
                        stateLock.unlock()
                    }
                }
            }
        }
    }

    // MARK: - Phase 3 Invariants (rate limit, clamp, thermal floor)

    /// Consume a rate-limiter token for an SMC-writing verb. `auto`/reset never calls
    /// this — reset must never be denied.
    private func allowWrite() -> Bool {
        rateLock.lock(); defer { rateLock.unlock() }
        return rateLimiter.allow(now: Date())
    }

    /// True while the thermal floor is overriding fans to max.
    private func isSuspended() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return safetySuspended
    }

    /// Clamp a requested RPM to the fan's cached [min, max]. Returns the value to apply
    /// and an advisory note if it was clamped (the command still succeeds).
    private func clampRPM(_ rpm: Float, fan: Int) -> (value: Float, note: String?) {
        guard fan >= 0, fan < fanLimits.count else { return (rpm, nil) }
        let limit = fanLimits[fan]
        if limit.max > 0 && rpm > limit.max {
            return (limit.max, "clamped \(Int(rpm)) → \(Int(limit.max)) RPM (max)")
        }
        if limit.min > 0 && rpm < limit.min {
            return (limit.min, "clamped \(Int(rpm)) → \(Int(limit.min)) RPM (min)")
        }
        return (rpm, nil)
    }

    /// Apply a held command STRING directly to the SMC — no hold bookkeeping, so it
    /// never touches lastBeat. Shared by wake re-apply and the thermal-floor restore.
    /// Caller holds smcLock.
    private func applyCommandString(_ command: String) throws {
        let parts = command.split(separator: " ")
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
    }

    // MARK: - Thermal Safety Floor

    /// 1s cadence: the client monitor at 100ms is primary; this is a backstop, and
    /// thermal mass doesn't move meaningfully in a second.
    private static let thermalCadence: TimeInterval = 1.0

    private func startThermalFloor() {
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                Thread.sleep(forTimeInterval: Self.thermalCadence)
                autoreleasepool { thermalTick() }
            }
        }
    }

    /// Peak CPU/GPU temperature. Production path reads each safety key under smcLock
    /// and RELEASES between keys: the read serializes with client writes (no torn SMC
    /// access — the defect this fixes) but never holds the lock longer than a single
    /// ~0.3ms read, so a full ~10ms sweep can't head-of-line-block a fan command.
    /// Sampling temps interleaved with writes is safe — a write changes fan speed, not
    /// the sensors, and a threshold check doesn't need an instantaneous snapshot.
    private func currentSafetyTemp() -> Float? {
        if let injected = injectedSampler { return injected() }
        var peak: Float = 0
        for key in FanControl.safetyTempKeys {
            smcLock.lock()
            let t = fanControl.readTemp(key)
            smcLock.unlock()
            if let t { peak = max(peak, t) }
        }
        return peak > 0 ? peak : nil
    }

    private func thermalTick() {
        // Read hold/suspension FIRST, and skip the SMC sweep entirely when there is no
        // hold and we aren't already overriding. Rationale (we will be asked): the floor
        // protects a HOLD. No hold means fans are on Apple's auto curve — macOS is
        // managing thermals and there is nothing for the floor to override, so a reading
        // it could not act on is not safety. The floor exists for one case: ThermalForge
        // has pinned fans below what the machine needs and something has gone wrong. The
        // client monitor at 100ms is the primary governor with its own override; this is
        // the backstop that survives the app's death. So an idle daemon does zero SMC
        // work per tick — only a live below-max hold (or an active suspension) samples.
        stateLock.lock()
        let suspended = safetySuspended
        let heldCommand = hold.command
        stateLock.unlock()

        guard suspended || heldCommand != nil else { return }

        guard let temp = currentSafetyTemp() else { return }

        switch thermalFloor.evaluate(temp: temp, holdCommand: heldCommand, suspended: suspended) {
        case .none:
            return

        case .engage:
            // Override the below-max hold to max. Direct SMC write — NEVER recordHold,
            // so the user's command + lastBeat are preserved for restore.
            smcLock.lock()
            let ok = (try? fanControl.setMax()) != nil
            smcLock.unlock()
            guard ok else { return }
            stateLock.lock(); safetySuspended = true; stateLock.unlock()
            DaemonLog.notice("ThermalForge daemon: thermal floor engaged at \(String(format: "%.1f", temp))°C; fans held at max (was \(heldCommand ?? "none"))")

        case .restore:
            // Re-read the hold at restore time — if none of ours is left to restore,
            // hand the fans back to Apple's auto control.
            stateLock.lock()
            let restoreCommand = hold.command
            stateLock.unlock()
            smcLock.lock()
            if let cmd = restoreCommand {
                try? applyCommandString(cmd)
            } else {
                try? fanControl.resetAuto()
            }
            smcLock.unlock()
            stateLock.lock(); safetySuspended = false; stateLock.unlock()
            DaemonLog.notice("ThermalForge daemon: thermal floor cleared at \(String(format: "%.1f", temp))°C; \(restoreCommand.map { "restored \($0)" } ?? "reset to auto")")
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
            DaemonLog.error("ThermalForge daemon: failed to register for power notifications")
            return
        }

        let source = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        DaemonLog.notice("ThermalForge daemon: registered for wake notifications")
    }

    private func handleWake() {
        stateLock.lock()
        let heldCommand = hold.command
        stateLock.unlock()
        guard let command = heldCommand else {
            DaemonLog.notice("ThermalForge daemon: woke; no profile to re-apply")
            return
        }

        DaemonLog.notice("ThermalForge daemon: woke; re-applying: \(command)")

        // Delay slightly — SMC needs a moment after wake
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) { [self] in
            smcLock.lock()
            defer { smcLock.unlock() }
            do {
                try applyCommandString(command)
                DaemonLog.notice("ThermalForge daemon: re-applied after wake")
            } catch {
                DaemonLog.error("ThermalForge daemon: wake re-apply failed: \(error)")
            }
        }
    }

    // MARK: - Request Processing

    /// Decode a request body → response: the framing/version/log wrapper around the
    /// atomic process(). smcLock is taken ONLY for the process() call — never around
    /// the I/O, so a slow-reading client can no longer hold it during the write.
    private func processFrame(_ body: Data) -> DaemonResponse {
        guard let request = try? DaemonProtocol.decode(DaemonRequest.self, from: body) else {
            // Undecodable = unknown verb or a shape from a newer client.
            return .unsupported(daemonVersion: ThermalForgeVersion.current)
        }
        // A newer protocol than we speak → tell the client our build so it can react.
        guard request.v <= DaemonProtocol.version else {
            return .unsupported(daemonVersion: ThermalForgeVersion.current)
        }
        smcLock.lock()
        let response = process(request)
        smcLock.unlock()
        // Verb + outcome only — never raw client bytes.
        DaemonLog.notice("ThermalForge daemon: verb=\(request.verb.rawValue) outcome=\(response.ok ? "ok" : (response.error?.rawValue ?? "error"))")
        return response
    }

    /// The full request dispatch — MOVED VERBATIM from the pre-Phase-4 serial handler.
    /// The CALLER holds smcLock for the whole call, so every check-then-act
    /// (blockedByCLIHold, rate limit, clamp, recordHold + SMC write) stays atomic exactly
    /// as before; Phase 4 concurrency lives only in the I/O around this, never inside it.
    /// Same-class concurrent writers resolve by last-write-wins (recordHold overwrites) —
    /// the one authority rule is cross-class (CLI outranks app via blockedByCLIHold);
    /// equal-authority ties are arbitrary-but-consistent by design, not by lock order.
    private func process(_ request: DaemonRequest) -> DaemonResponse {
        let response: DaemonResponse
        do {
            let oneshot = request.oneshot

            // Record a hold: unsupervised (CLI oneshot — never watchdog-reverted) or
            // supervised (app — reverted if it stops checking in). Overwrites whatever
            // was held, so an explicit app command cleanly takes over a CLI hold with
            // no orphan left behind. The command STRING is kept verbatim so wake
            // re-apply (handleWake) and the `state` snapshot are unchanged.
            func recordHold(_ heldCommand: String) {
                stateLock.lock()
                hold = oneshot
                    ? .unsupervised(command: heldCommand)
                    : .supervised(command: heldCommand, lastBeat: Date())
                stateLock.unlock()
            }

            // A supervised (app) command must NOT silently overwrite an unsupervised
            // CLI hold — the CLI hold wins and the app is told to yield via the error,
            // instead of clobbering it in the ~100ms before its next state poll.
            // `oneshot` commands and `auto` are never blocked, so explicit app takeover
            // (which sends `auto` first, clearing the hold) still works.
            func blockedByCLIHold() -> Bool {
                guard !oneshot else { return false }
                stateLock.lock(); defer { stateLock.unlock() }
                if case .unsupervised = hold { return true }
                return false
            }

            // Flood cap for SMC-writing verbs. `auto`/reset is exempt — a reset must
            // never be denied. Checked after usage validation (malformed requests
            // don't burn tokens), before the write.
            let rateLimited = DaemonResponse.failure(.rateLimited, "too many fan commands; try again shortly")

            switch request.verb {
            case .max:
                if !allowWrite() { response = rateLimited; break }
                if blockedByCLIHold() { response = .failure(.heldByCLI, "held by cli"); break }
                // Skip the SMC write while the thermal floor holds fans at max — record
                // the new hold to restore on cooldown, but don't drop fans while hot.
                if !isSuspended() { try fanControl.setMax() }
                recordHold("max")
                response = .ok()
            case .auto:
                // Exempt from the rate cap. Also the "hand back to Apple's auto curve"
                // path, so it clears any thermal suspension — Apple's auto handles heat.
                try fanControl.resetAuto()
                stateLock.lock(); hold = .none; safetySuspended = false; stateLock.unlock()
                response = .ok()
            case .set:
                guard let rpm = request.rpm else {
                    response = .failure(.usage, "usage: set <rpm>")
                    break
                }
                if !allowWrite() { response = rateLimited; break }
                if blockedByCLIHold() { response = .failure(.heldByCLI, "held by cli"); break }
                let (clamped, note) = clampRPM(Float(rpm), fan: 0)
                if !isSuspended() { try fanControl.setAllFans(rpm: clamped) }
                recordHold("set \(Int(clamped))")
                response = .ok(note: note, appliedRPM: Int(clamped))
            case .setfan:
                guard let index = request.fan, let rpm = request.rpm else {
                    response = .failure(.usage, "usage: setfan <index> <rpm>")
                    break
                }
                if !allowWrite() { response = rateLimited; break }
                if blockedByCLIHold() { response = .failure(.heldByCLI, "held by cli"); break }
                let (clamped, note) = clampRPM(Float(rpm), fan: index)
                if !isSuspended() { try fanControl.setSpeed(fan: index, rpm: clamped) }
                recordHold("setfan \(index) \(Int(clamped))")
                response = .ok(note: note, appliedRPM: Int(clamped))
            case .status:
                // Same snake_case shape as the standalone CLI `status`, carried as an
                // opaque payload string (no consumer decodes it today).
                let status = try fanControl.status()
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                let data = try encoder.encode(status)
                response = .statusResponse(String(data: data, encoding: .utf8) ?? "{}")
            case .state:
                // Current hold + owner (+ whether the thermal floor is overriding it),
                // so the app can reflect a CLI hold rather than fight or wipe it.
                stateLock.lock()
                let snap = hold.snapshot(safetySuspended: safetySuspended)
                stateLock.unlock()
                response = .stateResponse(snap)
            case .heartbeat:
                // Refreshes a SUPERVISED hold's liveness only. On an unsupervised CLI
                // hold this is deliberately a no-op — the app checking in must NOT
                // convert a CLI hold into a supervised one (the v0.1.5 bug).
                stateLock.lock()
                if case .supervised(let c, _) = hold {
                    hold = .supervised(command: c, lastBeat: Date())
                }
                stateLock.unlock()
                response = .ok()
            case .version:
                // Reports the build this daemon process is running, so a CLI from a
                // newer install can detect it's talking to a stale daemon.
                response = .versionResponse(ThermalForgeVersion.current)
            }
        } catch {
            response = .failure(.internal, "\(error)")
        }

        return response
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
