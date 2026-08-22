//
//  DaemonProtocol.swift
//  ThermalForge
//
//  Structured, versioned wire protocol between the CLI/app and the root daemon
//  (Phase 2). Length-prefixed JSON frames replace the newline-delimited string
//  commands and "error:"-prefixed replies of v0.1.x — no prefix sniffing anywhere.
//  The framing caps requests/responses so a hostile local process can't push the
//  root daemon into unbounded allocation.
//

import Darwin
import Foundation

public enum DaemonProtocol {
    /// Wire protocol version. A request carrying a newer version than the daemon
    /// understands is answered with `.unsupportedVersion` carrying the daemon's build.
    public static let version = 1

    /// Frame caps. Rejected at the length prefix, before the body is read/allocated.
    public static let maxRequestBytes = 4 * 1024
    public static let maxResponseBytes = 64 * 1024

    public enum FrameError: Error, Equatable {
        case oversized    // declared length exceeds the cap (genuine over-cap / hostile binary)
        case legacyPeer   // the peer is speaking the pre-Phase-2 string protocol
        case closed       // EOF / read error / timeout before the frame completed
        case write        // write error / timeout
    }

    // MARK: - Framing (4-byte big-endian length prefix + JSON body)

    /// Encode `value` as a length-prefixed frame, rejecting a body over `max`.
    public static func encodeFrame<T: Encodable>(_ value: T, max: Int) throws -> [UInt8] {
        let body = try JSONEncoder().encode(value)
        guard body.count <= max else { throw FrameError.oversized }
        let len = body.count
        var out = [UInt8]()
        out.reserveCapacity(4 + len)
        out.append(UInt8(truncatingIfNeeded: len >> 24))
        out.append(UInt8(truncatingIfNeeded: len >> 16))
        out.append(UInt8(truncatingIfNeeded: len >> 8))
        out.append(UInt8(truncatingIfNeeded: len))
        out.append(contentsOf: body)
        return out
    }

    /// Read one length-prefixed frame body from `fd`, rejecting a declared length
    /// over `max` BEFORE reading it (no unbounded allocation on a hostile prefix).
    public enum HeaderClass: Equatable {
        case length(Int)   // a real body length within the cap
        case legacyPeer    // pre-Phase-2 string peer
        case oversized     // over-cap / hostile binary
    }

    /// Classify a 4-byte length prefix. A legitimate frame length is <= 64KB, so
    /// header[0] is always 0x00; a peer still speaking the pre-Phase-2 string protocol
    /// sends text ("max\n", "error: ...") whose first byte is printable ASCII — the
    /// legacy signal, distinct from a non-ASCII over-cap/binary frame (hostile). Shared
    /// by the blocking client read and the daemon's async DispatchIO read so the two
    /// can't diverge. A valid frame never reaches the over-cap branch, so it can't be
    /// misread.
    public static func classifyHeader(_ header: [UInt8], max: Int) -> HeaderClass {
        let len = (Int(header[0]) << 24) | (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
        if len < 0 || len > max {
            return (header[0] >= 0x20 && header[0] <= 0x7e) ? .legacyPeer : .oversized
        }
        return .length(len)
    }

    public static func readFrame(_ fd: Int32, max: Int) throws -> Data {
        let header = try readFully(fd, 4)
        switch classifyHeader(header, max: max) {
        case .legacyPeer: throw FrameError.legacyPeer
        case .oversized: throw FrameError.oversized
        case .length(let len):
            guard len > 0 else { return Data() }
            return Data(try readFully(fd, len))
        }
    }

    /// Write all of `bytes` to `fd`, looping on partial writes.
    public static func writeFrame(_ fd: Int32, _ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { p in
                Darwin.write(fd, p.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
            guard n > 0 else { throw FrameError.write }   // 0 or -1 (incl. SO_SNDTIMEO)
            sent += n
        }
    }

    /// Decode a frame body.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    /// Read exactly `count` bytes, looping on partial reads; throws `.closed` if the
    /// peer closes or the bounded read times out (SO_RCVTIMEO) before they all arrive.
    private static func readFully(_ fd: Int32, _ count: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBytes { p in
                Darwin.read(fd, p.baseAddress!.advanced(by: got), count - got)
            }
            guard n > 0 else { throw FrameError.closed }   // 0 = EOF, -1 = error/timeout
            got += n
        }
        return buf
    }
}

// MARK: - Request

public struct DaemonRequest: Codable, Equatable {
    public enum Verb: String, Codable {
        case max, auto, set, setfan, status, state, heartbeat, version
    }

    /// Protocol version this client speaks.
    public var v: Int
    public var verb: Verb
    /// Target RPM for `set` / `setfan`.
    public var rpm: Int?
    /// Fan index for `setfan`.
    public var fan: Int?
    /// Apply as an unsupervised hold (heartbeat watchdog stays disarmed) — replaces
    /// the old trailing " oneshot" token. Meaningful only for hold verbs.
    public var oneshot: Bool

    public init(verb: Verb, rpm: Int? = nil, fan: Int? = nil, oneshot: Bool = false,
                v: Int = DaemonProtocol.version) {
        self.v = v
        self.verb = verb
        self.rpm = rpm
        self.fan = fan
        self.oneshot = oneshot
    }

    /// The wire request for a `FanCommand` — the exact mapping `DaemonClient.execute`
    /// uses (factored out so it's unit-testable without a socket). `oneshot` only
    /// takes on a hold command, mirroring the old token rule.
    public init(_ command: FanCommand, oneshot: Bool) {
        let os = oneshot && command.isHold
        switch command {
        case .setMax:
            self.init(verb: .max, oneshot: os)
        case .setRPM(let rpm):
            self.init(verb: .set, rpm: Int(rpm), oneshot: os)
        case .setFan(let index, let rpm):
            self.init(verb: .setfan, rpm: Int(rpm), fan: index, oneshot: os)
        case .resetAuto:
            self.init(verb: .auto)
        }
    }
}

// MARK: - Response

public enum DaemonErrorKind: String, Codable, Equatable {
    /// Malformed/insufficient arguments for the verb.
    case usage
    /// A supervised command was refused while an unsupervised CLI hold is active.
    case heldByCLI
    /// The request's protocol version (or verb) is newer than the daemon understands;
    /// the response's `version` carries the daemon's build so the client can react.
    case unsupportedVersion
    /// SMC-writing verbs exceeded the daemon's rate cap (flood protection). Reset
    /// (`auto`) is exempt and never rate-limited.
    case rateLimited
    /// The daemon hit an internal error applying the verb (e.g. an SMC write failed).
    case `internal`
}

public struct DaemonResponse: Codable, Equatable {
    public var v: Int
    public var ok: Bool
    /// Set when `ok == false`.
    public var error: DaemonErrorKind?
    public var message: String?
    /// Daemon build — carried by `version` (ok) and by `unsupportedVersion`.
    public var version: String?
    /// `status` payload: the daemon's ThermalStatus JSON (same snake_case shape as
    /// the standalone CLI `status`). Opaque to the protocol; no consumer decodes it today.
    public var statusJSON: String?
    /// `state` payload.
    public var state: DaemonHoldState?
    /// Advisory result note on an OK response — e.g. "clamped 999999 → 3500 RPM (max)".
    /// Not an error; the command was applied (with the clamped value).
    public var note: String?
    /// The RPM the daemon actually applied after clamping — the authoritative value for
    /// a CLI echo, so it never re-reads the target register (which lags a command by ~1s
    /// and would print a stale RPM) or recomputes the clamp (a second source that can
    /// drift). Set on OK `set`/`setfan`; nil otherwise.
    public var appliedRPM: Int?

    public init(ok: Bool, error: DaemonErrorKind? = nil, message: String? = nil,
                version: String? = nil, statusJSON: String? = nil, state: DaemonHoldState? = nil,
                note: String? = nil, appliedRPM: Int? = nil, v: Int = DaemonProtocol.version) {
        self.v = v
        self.ok = ok
        self.error = error
        self.message = message
        self.version = version
        self.statusJSON = statusJSON
        self.state = state
        self.note = note
        self.appliedRPM = appliedRPM
    }

    public static func ok(note: String? = nil, appliedRPM: Int? = nil) -> DaemonResponse {
        .init(ok: true, note: note, appliedRPM: appliedRPM)
    }
    public static func failure(_ kind: DaemonErrorKind, _ message: String) -> DaemonResponse {
        .init(ok: false, error: kind, message: message)
    }
    public static func versionResponse(_ version: String) -> DaemonResponse {
        .init(ok: true, version: version)
    }
    public static func statusResponse(_ json: String) -> DaemonResponse {
        .init(ok: true, statusJSON: json)
    }
    public static func stateResponse(_ state: DaemonHoldState) -> DaemonResponse {
        .init(ok: true, state: state)
    }
    public static func unsupported(daemonVersion: String) -> DaemonResponse {
        .init(ok: false, error: .unsupportedVersion, message: "unsupported protocol version",
              version: daemonVersion)
    }
}
