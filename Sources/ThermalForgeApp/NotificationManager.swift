//
//  NotificationManager.swift
//  ThermalForge
//
//  UNUserNotification delivery for thermal events:
//  - Safety override triggered / cleared
//  - Thermal throttle (serious / critical)
//  - Temperature anomaly (spike / sustained)
//  - Battery alerts (condition, cycle count, low capacity)
//
//  Designed to avoid notification spam:
//  - Each category has a minimum re-fire interval
//  - "Cleared" notifications only fire if the matching alert fired this session
//

import Foundation
import UserNotifications
import ThermalForgeCore

// MARK: - Notification Category IDs

private enum NotifCategory: String {
    case safetyOverride   = "tf.safety"
    case thermalThrottle  = "tf.throttle"
    case tempAnomaly      = "tf.anomaly"
    case battery          = "tf.battery"
}

// MARK: - NotificationManager

@MainActor
public final class NotificationManager: ObservableObject {

    public static let shared = NotificationManager()
    private init() {}

    // MARK: - Permission

    /// Request notification permission on first launch.
    /// Safe to call multiple times — UNUserNotificationCenter handles dedup.
    public func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                TFLogger.shared.error("Notification permission error: \(error)")
            }
        }
    }

    // MARK: - Throttle State

    /// Whether we have fired a safety override notification this session (so we can fire "cleared").
    private var safetyFired = false
    /// Whether we have fired a throttle notification this session.
    private var throttleFired = false
    /// Last anomaly notification time — suppress if < 60s ago.
    private var lastAnomalyFire: Date?
    /// Last throttle notification time.
    private var lastThrottleFire: Date?
    /// Minimum interval between anomaly notifications.
    private let anomalyCooldown: TimeInterval = 60
    /// Minimum interval between throttle notifications.
    private let throttleCooldown: TimeInterval = 30

    // MARK: - Safety Override

    public func fireSafetyOverride(temp: Float) {
        safetyFired = true
        let body = String(format: "Peak temperature %.0f°C — fans forced to max.", temp)
        deliver(
            id: "safety-override",
            title: "🌡 Thermal Safety Override",
            body: body,
            category: .safetyOverride,
            interruptionLevel: .timeSensitive
        )
    }

    public func fireSafetyCleared(temp: Float) {
        guard safetyFired else { return }
        safetyFired = false
        let body = String(format: "Temperature dropped to %.0f°C — returning to active profile.", temp)
        deliver(
            id: "safety-cleared",
            title: "✅ Safety Override Cleared",
            body: body,
            category: .safetyOverride,
            interruptionLevel: .active
        )
    }

    // MARK: - Thermal Throttle

    public func fireThermalThrottle(level: String) {
        let now = Date()
        if let last = lastThrottleFire, now.timeIntervalSince(last) < throttleCooldown { return }
        lastThrottleFire = now
        throttleFired = true

        let body: String
        switch level {
        case "critical":
            body = "Your Mac is critically throttled. Close intensive apps or switch to Max profile."
        default: // serious
            body = "Your Mac is thermally throttled. Performance may be reduced."
        }
        deliver(
            id: "thermal-throttle",
            title: "⚠️ Thermal Throttling (\(level.capitalized))",
            body: body,
            category: .thermalThrottle,
            interruptionLevel: .timeSensitive
        )
    }

    public func fireThermalThrottleCleared() {
        guard throttleFired else { return }
        throttleFired = false
        deliver(
            id: "throttle-cleared",
            title: "✅ Throttling Cleared",
            body: "Mac is back to nominal thermal state.",
            category: .thermalThrottle,
            interruptionLevel: .passive
        )
    }

    // MARK: - Temperature Anomaly

    public func fireTempAnomaly(kind: String, fromTemp: Float, toTemp: Float, deltaSeconds: Int) {
        let now = Date()
        if let last = lastAnomalyFire, now.timeIntervalSince(last) < anomalyCooldown { return }
        lastAnomalyFire = now

        let delta = toTemp - fromTemp
        let direction = delta > 0 ? "spike" : "drop"
        let body = String(
            format: "%.0f→%.0f°C (%+.0f°C in %ds) — check active workloads.",
            fromTemp, toTemp, delta, deltaSeconds
        )
        deliver(
            id: "temp-anomaly",
            title: "📈 Temperature \(direction.capitalized) (\(kind))",
            body: body,
            category: .tempAnomaly,
            interruptionLevel: .active
        )
    }

    // MARK: - Battery Alerts

    public func fireBatteryAlert(_ alert: BatteryAlert) {
        let (title, body): (String, String)
        switch alert {
        case .conditionChanged(let cond):
            switch cond {
            case .serviceSoon:
                title = "🔋 Battery Service Recommended"
                body = "Your battery health has declined. Consider servicing soon."
            case .serviceNow:
                title = "🔋 Service Battery Now"
                body = "Your battery needs service. Capacity may be significantly reduced."
            default:
                return // Don't notify on normal
            }
        case .cycleCountHigh(let n):
            title = "🔋 Battery Cycle Count: \(n)"
            body = "Your battery has exceeded 500 charge cycles. Monitor health regularly."
        case .cycleCountVeryHigh(let n):
            title = "🔋 Battery Cycle Count: \(n)"
            body = "Your battery has exceeded 1000 charge cycles. Consider replacement if capacity drops."
        case .lowCapacity(let pct):
            title = "🔋 Low Battery Capacity (\(pct)%)"
            body = "Your battery is at \(pct)% of original capacity. Apple considers <80% degraded."
        case .overCurrent:
            title = "⚡️ Battery Over-Current"
            body = "Abnormal current detected. Check charger and cable."
        case .overVoltage:
            title = "⚡️ Battery Over-Voltage"
            body = "Abnormal voltage detected. Stop charging and check hardware."
        }
        deliver(
            id: "battery-\(alert.alertID)",
            title: title,
            body: body,
            category: .battery,
            interruptionLevel: .active
        )
    }

    // MARK: - Delivery

    private func deliver(
        id: String,
        title: String,
        body: String,
        category: NotifCategory,
        interruptionLevel: UNNotificationInterruptionLevel
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category.rawValue
        content.interruptionLevel = interruptionLevel
        // Use default sound for time-sensitive, no sound for passive
        if interruptionLevel != .passive {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: nil // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                TFLogger.shared.error("Notification delivery failed [\(id)]: \(error)")
            }
        }
    }
}

// MARK: - BatteryAlert ID helper (for dedup)

private extension BatteryAlert {
    var alertID: String {
        switch self {
        case .conditionChanged(let c): return "condition-\(c.rawValue)"
        case .cycleCountHigh:         return "cycles-500"
        case .cycleCountVeryHigh:     return "cycles-1000"
        case .lowCapacity(let p):     return "capacity-\(p)"
        case .overCurrent:            return "overcurrent"
        case .overVoltage:            return "overvoltage"
        }
    }
}
