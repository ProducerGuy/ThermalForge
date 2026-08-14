//
//  FanCommandRouter.swift
//  ThermalForge
//
//  Single entry point for applying a fan command. Prefers the privileged daemon
//  (no sudo, coordinates with the menu bar app) when it's running; falls back to
//  direct SMC writes (root required) otherwise — so daemon-less installs behave
//  exactly as before.
//

import Darwin
import Foundation

/// How a fan command was applied. Lets the CLI print one clear message — never
/// silently — including when the daemon is a different or older build.
public enum FanRoute: Equatable {
    /// Applied by writing SMC directly — no daemon running. Nothing to warn about.
    case direct
    /// Applied via the running daemon. Carries the daemon's reported version (nil
    /// if it predates the `version` command) so the CLI can warn on a mismatch.
    case daemon(daemonVersion: String?)
    /// Applied via the daemon, but it predates the 0.1.5 `oneshot` protocol, so an
    /// unsupervised hold will be reverted to auto by the watchdog (~15s).
    case daemonHoldWillRevert(daemonVersion: String)
    /// A per-fan command hit a daemon too old for `setfan`, and we were root, so it
    /// fell back to a direct SMC write. Distinguished so the CLI can nudge a re-sync.
    case directOldDaemon(daemonVersion: String)
}

public enum FanRouteError: Error, LocalizedError, CustomStringConvertible {
    /// A manual fan write needs root and there's no daemon to do it for us.
    case rootRequired
    /// Per-fan write needs root because the running daemon is too old for `setfan`.
    case perFanNeedsNewerDaemon(daemonVersion: String)

    public var description: String {
        switch self {
        case .rootRequired:
            return """
                This fan command needs root, and no daemon is running to do it for you.
                Run it with sudo, or install the background daemon:  sudo thermalforge install
                """
        case .perFanNeedsNewerDaemon(let version):
            return """
                The background daemon (\(version)) is too old to set individual fans, so this needs \
                a direct hardware write (root).
                Run it with sudo, or re-sync the daemon:  sudo thermalforge install
                """
        }
    }

    public var errorDescription: String? { description }
}

public enum FanCommandRouter {
    /// Apply a fan command by the best available path.
    /// - oneshot: for one-shot CLI holds — asks the daemon not to arm its
    ///   heartbeat watchdog so the hold persists. Ignored by the direct path and
    ///   for resetAuto.
    public static func apply(_ command: FanCommand, oneshot: Bool) throws -> FanRoute {
        guard ThermalForgeDaemon.isRunning else {
            try applyDirect(command)   // fails fast if a hold needs root
            return .direct
        }

        let client = DaemonClient()
        let daemonVersion = reportedVersion(client)
        let supportsProtocol = daemonVersion.map {
            ThermalForgeVersion.atLeast($0, ThermalForgeVersion.oneshotProtocolSince)
        } ?? false

        // Per-fan needs the 0.1.5 `setfan` verb; older daemons reject it, so it
        // must fall back to a direct SMC write (root). Fail fast WITH the reason
        // when we're not root, so the explanation reaches the person who hit it —
        // instead of a bare unlock timeout after applyDirect would throw.
        if command.isPerFan && !supportsProtocol {
            guard geteuid() == 0 else {
                throw FanRouteError.perFanNeedsNewerDaemon(daemonVersion: daemonVersion ?? "an older build")
            }
            try applyDirect(command)
            return .directOldDaemon(daemonVersion: daemonVersion ?? "an older build")
        }

        try client.execute(command, oneshot: oneshot)

        // A hold sent with oneshot to a daemon that doesn't understand the token
        // will be reverted by the watchdog — surface it rather than let it happen.
        if oneshot && command.isHold && !supportsProtocol {
            return .daemonHoldWillRevert(daemonVersion: daemonVersion ?? "an older build")
        }
        return .daemon(daemonVersion: daemonVersion)
    }

    private static func applyDirect(_ command: FanCommand) throws {
        // Manual fan writes require root; without it the SMC unlock loop hangs
        // ~10s before failing (issue #22). Fail fast instead. resetAuto is exempt
        // — releasing to Apple's auto mode doesn't need the unlock.
        if command.isHold && geteuid() != 0 {
            throw FanRouteError.rootRequired
        }
        let fc = try FanControl()
        switch command {
        case .setMax: try fc.setMax()
        case .setRPM(let rpm): try fc.setAllFans(rpm: rpm)
        case .setFan(let index, let rpm): try fc.setSpeed(fan: index, rpm: rpm)
        case .resetAuto: try fc.resetAuto()
        }
    }

    /// The daemon's reported version, or nil if it can't be determined — a daemon
    /// old enough to predate the `version` command also predates the
    /// oneshot/setfan protocol, so nil is treated as "unsupported".
    private static func reportedVersion(_ client: DaemonClient) -> String? {
        guard let reply = try? client.sendRaw("version"),
              !reply.hasPrefix("error:"), !reply.isEmpty
        else { return nil }
        return reply
    }
}
