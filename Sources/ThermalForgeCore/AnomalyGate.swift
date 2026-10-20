//
//  AnomalyGate.swift
//  ThermalForge
//
//  Pure decision logic for the monitor-cadence anomaly detector (temperature
//  spikes/drops). Hardware-free so it unit-tests without SMC —
//  ThermalMonitor performs the logging; this type only decides.
//
//  The cooldown exists because the bare thresholds misfire continuously on
//  Apple Silicon: P-core peak sensors oscillate ±5°C on a 2-4s scale under
//  normal load, so the old code logged an "Instant spike/drop" event (plus a
//  15-line process-history dump) every few seconds — 11,700+ events/day in
//  measured logs (~200k log lines/day). A genuine thermal event reports
//  immediately; the echo-chamber of threshold-edge oscillation does not.
//

import Foundation

public struct AnomalyGate {
    /// 2-second delta above which an instant event is reported.
    public let instantThreshold: Float
    /// 30-second delta above which a sustained event is reported.
    public let sustainedThreshold: Float
    /// Minimum spacing between REPORTED events. Samples arriving inside the
    /// window still feed the history (the detector stays warm) but are not
    /// reported — that is the threshold-edge oscillation filter.
    public let cooldownSeconds: TimeInterval

    /// Rolling temperature window (15 readings × 2s = 30s).
    private(set) var history: [Float] = []
    private var lastReportedAt: Date?

    private static let historyCapacity = 15

    public init(instantThreshold: Float = 5,
                sustainedThreshold: Float = 10,
                cooldownSeconds: TimeInterval = 60) {
        self.instantThreshold = instantThreshold
        self.sustainedThreshold = sustainedThreshold
        self.cooldownSeconds = cooldownSeconds
    }

    public enum Event: Equatable {
        /// |temp − previous| above the 2-second threshold.
        case instant(from: Float, to: Float)
        /// |temp − 30s-ago| above the window threshold.
        case sustained(from: Float, to: Float)
        /// Nothing reportable this sample (below thresholds, or in cooldown).
        case none
    }

    /// Feed one 2-second sample. Maintains the rolling history and returns the
    /// event to report, if any. At most one event per call: when both tiers
    /// qualify the instant tier wins (it is the tighter, earlier signal; the
    /// sustained tier fires on a later sample once the instant one is reported).
    public mutating func evaluate(temp: Float, at now: Date = Date()) -> Event {
        defer {
            history.append(temp)
            if history.count > Self.historyCapacity { history.removeFirst() }
        }

        let candidate: Event
        if let prev = history.last, abs(temp - prev) > instantThreshold {
            candidate = .instant(from: prev, to: temp)
        } else if history.count >= Self.historyCapacity, let oldest = history.first,
                  abs(temp - oldest) > sustainedThreshold {
            candidate = .sustained(from: oldest, to: temp)
        } else {
            return .none
        }

        if let last = lastReportedAt, now.timeIntervalSince(last) < cooldownSeconds {
            return .none
        }
        lastReportedAt = now
        if case .sustained = candidate { history.removeAll() }
        return candidate
    }
}
