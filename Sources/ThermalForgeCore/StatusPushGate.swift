//
//  StatusPushGate.swift
//  ThermalForge
//
//  Pure decision logic for when the monitor pushes UI state (onUpdate).
//  Hardware-free so it unit-tests without SMC.
//
//  The gate exists because the menu bar UI re-renders on every push:
//  @Published properties change → SwiftUI MenuBarExtra rebuilds its view
//  graph and NSStatusItem replicant snapshot. At the old 500ms cadence the
//  menu's contents are mid-rebuild a meaningful fraction of the time it is
//  open, which can eat a picker tap (an observed failure mode: a profile
//  switch click vanishing with no log line — the SwiftUI identity changed
//  under the click). One-second cadence keeps the display lively while
//  shrinking the rebuild window, and visible changes (profile, monitor
//  state) still push immediately so the UI never lags a user action by a
//  full second.
//

import Foundation

public struct StatusPushGate {
    /// Push at least every N monitor ticks.
    public let intervalTicks: Int

    private var lastPushedTick: Int?
    private var lastPushedProfileID: String?
    private var lastPushedState: MonitorState?

    public init(intervalTicks: Int) {
        precondition(intervalTicks >= 1, "intervalTicks must be at least 1")
        self.intervalTicks = intervalTicks
    }

    /// Whether this tick should push. `true` when the cadence is due OR the
    /// visible identity (profile, state) changed since the last push — a
    /// switch or a safety transition must not wait out the interval.
    public mutating func shouldPush(tick: Int, profileID: String, state: MonitorState) -> Bool {
        let cadenceDue = lastPushedTick.map { tick - $0 >= intervalTicks } ?? true
        let visibleChange = profileID != lastPushedProfileID || state != lastPushedState
        guard cadenceDue || visibleChange else { return false }
        lastPushedTick = tick
        lastPushedProfileID = profileID
        lastPushedState = state
        return true
    }
}
