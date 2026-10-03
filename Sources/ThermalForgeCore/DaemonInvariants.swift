//
//  DaemonInvariants.swift
//  ThermalForge
//
//  Pure, hardware-free decision logic for the Phase 3 daemon-enforced invariants:
//  a token-bucket rate limiter for SMC-writing verbs, and the thermal-safety-floor
//  state decision. Both take injected inputs (a clock, a temperature) so they unit
//  test without a bound socket or SMC. The DaemonServer performs the actual SMC and
//  state effects; these types only decide.
//

import Foundation

/// Token-bucket rate limiter for the daemon's SMC-writing verbs (`max`/`set`/`setfan`
/// — `auto`/reset is exempt). Burst capacity absorbs a legitimate pump ramp (~10/s,
/// coalescing under backpressure) while a flood drains it to the refill rate and gets
/// `rateLimited`. The clock is injected so the boundary is testable without waiting.
public struct RateLimiter {
    private let capacity: Double
    private let refillPerSecond: Double
    private var tokens: Double
    private var last: Date

    public init(capacity: Double = 20, refillPerSecond: Double = 10, now: Date) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.tokens = capacity
        self.last = now
    }

    /// Refill for elapsed time, then consume one token if available.
    public mutating func allow(now: Date) -> Bool {
        let elapsed = max(0, now.timeIntervalSince(last))
        last = now
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

/// The thermal safety floor's decision, given a sampled temperature and the current
/// hold/suspension state. Thresholds are mirrored from `FanProfile` (read, not
/// invented). The DaemonServer maps `.engage`/`.restore` onto SMC + `safetySuspended`.
public struct ThermalFloor {
    public let threshold: Float
    public let clearBelow: Float

    public init(threshold: Float = FanProfile.safetyTempThreshold,
                hysteresis: Float = FanProfile.hysteresisDegrees) {
        self.threshold = threshold
        self.clearBelow = threshold - hysteresis
    }

    public enum Action: Equatable {
        case none
        case engage    // overheating while a below-max hold is active → override to max
        case restore   // cooled below the hysteresis point → restore the hold (or auto)
    }

    /// - suspended: is the floor currently overriding fans to max?
    /// - holdCommand: the active hold's command string, or nil for auto / no hold.
    public func evaluate(temp: Float, holdCommand: String?, suspended: Bool) -> Action {
        if suspended {
            // Restore only once cooled past the hysteresis point; otherwise keep max.
            return temp < clearBelow ? .restore : .none
        }
        // Engage only when overheating AND a hold pins fans below max. No hold (auto)
        // or an already-max hold needs no override.
        guard temp >= threshold, let cmd = holdCommand, cmd != "max" else { return .none }
        return .engage
    }
}

// MARK: - Peer authentication

/// A connected peer's effective uid/gid, as the kernel recorded them at connect().
struct PeerCredentials: Equatable {
    let uid: uid_t
    let gid: gid_t
}

/// Why a peer's credentials couldn't be read. Any such failure is a rejection.
struct PeerCredentialError: Error, Equatable {
    let errno: Int32
}

/// The per-connection peer check's verdict. Only `.allow` gets a handler.
enum PeerDecision: Equatable {
    case allow(PeerCredentials)
    case reject(PeerCredentials)
    case unavailable(errno: Int32)
}

/// What ConnectionServer needs from a peer check: a verdict per accepted fd, and the
/// allowed set for the rejection log. Injected so tests can supply a fake.
protocol PeerAuthorizing {
    func decide(fd: Int32) -> PeerDecision
    var allowedDescription: String { get }
}

/// Second layer behind the socket's 0600 permissions: only root and the daemon's
/// owner may talk to it. Credentials come from getpeereid(), which reads the
/// LOCAL_PEERCRED copy the kernel took at connect() — still valid after the peer
/// exits, so the check can't race the peer going away.
struct PeerAuthorizer: PeerAuthorizing {
    let ownerUID: uid_t
    private let credentials: (Int32) -> Result<PeerCredentials, PeerCredentialError>

    init(ownerUID: uid_t,
         credentials: @escaping (Int32) -> Result<PeerCredentials, PeerCredentialError> = PeerAuthorizer.kernelCredentials) {
        self.ownerUID = ownerUID
        self.credentials = credentials
    }

    /// True only for root and the owner.
    static func allows(uid: uid_t, ownerUID: uid_t) -> Bool {
        uid == 0 || uid == ownerUID
    }

    func decide(fd: Int32) -> PeerDecision {
        switch credentials(fd) {
        case .success(let peer):
            return Self.allows(uid: peer.uid, ownerUID: ownerUID) ? .allow(peer) : .reject(peer)
        case .failure(let error):
            return .unavailable(errno: error.errno)
        }
    }

    var allowedDescription: String { "uid 0, owner uid \(ownerUID)" }

    static func kernelCredentials(_ fd: Int32) -> Result<PeerCredentials, PeerCredentialError> {
        // Start from values that can never pass the policy, so no path defaults to root.
        var uid = uid_t.max
        var gid = gid_t.max
        guard getpeereid(fd, &uid, &gid) == 0 else {
            return .failure(PeerCredentialError(errno: errno))
        }
        return .success(PeerCredentials(uid: uid, gid: gid))
    }
}

/// Bounds the rejection log so a hostile local process can't flood the system log:
/// a burst of 5 lines, then one per minute. Suppressed rejections are counted; the
/// count rides on the next line that gets through, or on the summary the caller
/// emits from its one-shot timer (`flush`). The clock is injected for tests.
struct RejectionLogLimiter {
    private var limiter: RateLimiter
    private(set) var suppressed = 0

    init(now: Date) {
        limiter = RateLimiter(capacity: 5, refillPerSecond: 1.0 / 60, now: now)
    }

    /// The line to log for this rejection, or nil when it's suppressed.
    mutating func record(_ message: String, now: Date) -> String? {
        guard limiter.allow(now: now) else {
            suppressed += 1
            return nil
        }
        defer { suppressed = 0 }
        return suppressed > 0
            ? "\(message) (\(suppressed) earlier rejections suppressed)"
            : message
    }

    /// Summary of rejections suppressed since the last line, or nil if none.
    mutating func flush() -> String? {
        guard suppressed > 0 else { return nil }
        defer { suppressed = 0 }
        return "ThermalForge daemon: \(suppressed) further peer rejections suppressed"
    }
}
