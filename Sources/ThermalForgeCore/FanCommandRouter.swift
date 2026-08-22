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
    /// The running daemon predates the Phase 2 framed protocol (upgrade window), so it
    /// couldn't take the command; we were root and applied it directly. The CLI nudges
    /// the reinstall that reconnects the daemon on the new protocol.
    case directLegacyDaemon

    /// True when the command was applied BY the daemon (vs a direct SMC write). A daemon
    /// route that returns a nil appliedRPM means the daemon is too old (pre-0.2.1) to
    /// report the value — so the CLI must not fall back to echoing the raw request as if
    /// the daemon confirmed it.
    public var wentThroughDaemon: Bool {
        switch self {
        case .daemon, .daemonHoldWillRevert: return true
        case .direct, .directLegacyDaemon, .directOldDaemon: return false
        }
    }
}

public enum FanRouteError: Error, LocalizedError, CustomStringConvertible {
    /// A manual fan write needs root and there's no daemon to do it for us.
    case rootRequired
    /// Per-fan write needs root because the running daemon is too old for `setfan`.
    case perFanNeedsNewerDaemon(daemonVersion: String)
    /// The running daemon predates the Phase 2 framed protocol and we aren't root, so
    /// we can't apply directly either. Only the reinstall fixes it for good.
    case legacyDaemonNeedsReinstall

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
        case .legacyDaemonNeedsReinstall:
            return """
                The background daemon is an older build that can't use the updated control protocol.
                Finish the upgrade to reconnect it:  sudo thermalforge install
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
    /// Returns the route taken plus an advisory note from the daemon (e.g. a clamp),
    /// which is a command *result* — kept off FanRoute, which is only about routing.
    public static func apply(_ command: FanCommand, oneshot: Bool) throws -> (route: FanRoute, note: String?, appliedRPM: Int?) {
        guard ThermalForgeDaemon.isRunning else {
            try applyDirect(command)   // fails fast if a hold needs root
            return (.direct, nil, nil)
        }

        let client = DaemonClient()

        // Classify the daemon FIRST. A pre-Phase-2 (string) daemon can't parse our
        // frames, and its socket is up (isRunning true), so it wouldn't take the
        // daemon-down direct path on its own. Detecting it here — BEFORE the per-fan
        // gate — is what makes EVERY verb get the reinstall diagnosis in the upgrade
        // window, instead of a "needs a newer daemon" misread on the per-fan path
        // (where a nil version would otherwise look like a pre-`setfan` daemon).
        let daemonVersion: String?
        switch probeDaemon(client) {
        case .legacy:
            guard geteuid() == 0 else { throw FanRouteError.legacyDaemonNeedsReinstall }
            try applyDirect(command)
            return (.directLegacyDaemon, nil, nil)
        case .version(let v):
            daemonVersion = v
        case .unreachable:
            // isRunning saw the socket up but the version probe couldn't complete (a
            // transient in between, or the daemon died right after). Treat the version
            // as UNKNOWN — not old — so the per-fan/hold-revert gates below don't
            // misdiagnose it; execute() runs and surfaces the real error.
            daemonVersion = nil
        }

        // "Known unsupported" = we have a REAL version and it's below the oneshot/setfan
        // threshold. A nil version now means "unknown" (an unreachable probe), NOT
        // "old": after Phase 1 a genuinely old daemon can't speak frames and is caught
        // as .legacy above. So unknown must not masquerade as old on the per-fan or
        // hold-revert paths — that was this same misdiagnosis one layer down.
        let protocolKnownUnsupported = daemonVersion.map {
            !ThermalForgeVersion.atLeast($0, ThermalForgeVersion.oneshotProtocolSince)
        } ?? false

        // Per-fan needs the 0.1.5 `setfan` verb; a daemon KNOWN to predate it must fall
        // back to a direct SMC write (root). Fires only for a positively-old daemon now
        // — never for legacy (handled above) or unknown (falls through to execute, which
        // surfaces the real error). Fail fast WITH the reason when we're not root.
        if command.isPerFan && protocolKnownUnsupported {
            guard geteuid() == 0 else {
                throw FanRouteError.perFanNeedsNewerDaemon(daemonVersion: daemonVersion ?? "an older build")
            }
            try applyDirect(command)
            return (.directOldDaemon(daemonVersion: daemonVersion ?? "an older build"), nil, nil)
        }

        // Backstop: a daemon that turned legacy between the probe and here (restarted
        // mid-call) still gets the reinstall path, not a raw FrameError. Only this
        // specifically-detected condition falls back — any other error propagates.
        // The daemon's advisory note (e.g. a clamp) rides back through execute().
        let result: FanApplyResult
        do {
            result = try client.execute(command, oneshot: oneshot)
        } catch DaemonError.incompatibleDaemon {
            guard geteuid() == 0 else { throw FanRouteError.legacyDaemonNeedsReinstall }
            try applyDirect(command)
            return (.directLegacyDaemon, nil, nil)
        }

        // A hold sent with oneshot to a daemon KNOWN to predate the token will be
        // reverted by the watchdog — surface it. Gated on known-old (not unknown) for
        // the same reason as the per-fan path above.
        if oneshot && command.isHold && protocolKnownUnsupported {
            return (.daemonHoldWillRevert(daemonVersion: daemonVersion ?? "an older build"), result.note, result.appliedRPM)
        }
        return (.daemon(daemonVersion: daemonVersion), result.note, result.appliedRPM)
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

    /// How the running daemon answered a `version` probe.
    private enum DaemonProbe {
        case version(String?)   // reachable framed daemon; String? is its build if named
        case legacy             // pre-Phase-2 string daemon (couldn't parse our frame)
        case unreachable        // probe couldn't complete (down / transient)
    }

    /// Classify the daemon by probing `version`. A daemon old enough to predate the
    /// `version` verb also predates the oneshot/setfan protocol, so a named-but-nil
    /// build is treated as "unsupported"; a pre-Phase-2 string daemon is `.legacy`.
    private static func probeDaemon(_ client: DaemonClient) -> DaemonProbe {
        do {
            let response = try client.request(DaemonRequest(verb: .version))
            // Both `version` (ok) and `unsupportedVersion` carry the daemon's build.
            if response.ok { return .version(response.version) }
            if response.error == .unsupportedVersion { return .version(response.version) }
            return .version(nil)
        } catch DaemonError.incompatibleDaemon {
            return .legacy
        } catch {
            return .unreachable
        }
    }
}
