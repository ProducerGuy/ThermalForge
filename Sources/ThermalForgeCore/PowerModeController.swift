//
//  PowerModeController.swift
//  ThermalForge
//
//  The overheat protection loop — the built-in successor of
//  powermode_controller-v1.py: when the hottest reported sensor crosses HIGH
//  (default 88°C, 2° below the 90°C danger zone) the system is dropped to
//  reduced performance; when it cools below LOW (default 70°C) high
//  performance is restored — on AC only; while the system runs on battery
//  protection never restores high (user safety floor), it stays reduced
//  until the system is back on AC. The wide 18° hysteresis band prevents
//  cycling,
//  and there is deliberately NO sustained trigger — for a safety feature a
//  single reading above the threshold acts immediately.
//
//  Sets always target the power domain the system is currently drawing from
//  (`-c` on AC, `-b` on battery — an AC-only set is invisible to the
//  effective read while on battery). The power source is tracked in-process
//  by an IOKit notification monitor (no polling, no pmset for the source).
//
//  Cadence is caller-driven: the app feeds `evaluate(peakTemp:)` on the
//  existing 100ms thermal tick and `refreshMode()` on the 2s monitor tick.
//  All state lives on one serial queue — pmset I/O never touches the caller's
//  thread — which also makes every operation race-free by construction.
//

import Foundation

// MARK: - Configuration

/// User-tunable protection parameters. Persisted in the app's UserDefaults;
/// the menu bar GUI is the editor (in-process writes, no polling).
public struct PowerModeConfig: Equatable, Sendable {
    /// Master switch. Off = the controller stops acting (the last system
    /// mode is left in place — never force-restored on disable).
    public var enabled: Bool
    /// ≥ this → reduced performance. Default 88°C.
    public var highTemp: Float
    /// ≤ this → high performance again. Default 70°C.
    public var lowTemp: Float

    public static let `default` = PowerModeConfig(enabled: true, highTemp: 88, lowTemp: 70)

    static let enabledKey = "powerProtectionEnabled"
    static let highTempKey = "powerProtectionHighTemp"
    static let lowTempKey = "powerProtectionLowTemp"

    private static let highRange: ClosedRange<Float> = 50...100
    private static let lowRange: ClosedRange<Float> = 30...95

    public init(enabled: Bool = true, highTemp: Float = 88, lowTemp: Float = 70) {
        self.enabled = enabled
        self.highTemp = highTemp
        self.lowTemp = lowTemp
    }

    /// Load from a UserDefaults store, falling back to defaults for each key.
    public init(defaults: UserDefaults = .standard) {
        self.init(
            enabled: defaults.object(forKey: Self.enabledKey) as? Bool ?? true,
            highTemp: Float(defaults.object(forKey: Self.highTempKey) as? Double ?? 88),
            lowTemp: Float(defaults.object(forKey: Self.lowTempKey) as? Double ?? 70)
        )
        validate()
    }

    /// Clamp to sane ranges. The low threshold is additionally capped at
    /// (high − 2) so a usable hysteresis gap can never be configured away.
    public mutating func validate() {
        highTemp = min(max(highTemp, Self.highRange.lowerBound), Self.highRange.upperBound)
        lowTemp = min(max(lowTemp, Self.lowRange.lowerBound), highTemp - 2)
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(Double(highTemp), forKey: Self.highTempKey)
        defaults.set(Double(lowTemp), forKey: Self.lowTempKey)
    }
}

// MARK: - State

/// Everything the UI needs to show, plus what the controller believes.
public struct PowerModeControllerState: Equatable, Sendable {
    /// Last *verified* effective system mode; nil = not yet determined.
    public var currentMode: PowerMode? = nil
    public var enabled: Bool
    public var highTemp: Float
    public var lowTemp: Float
    /// Set/verification failure to surface in the UI; nil when healthy.
    public var warning: String? = nil
    /// Where the system is drawing power (drives the battery rule and the
    /// set-domain choice).
    public var powerSource: PowerSourceState = .unknown

    public init(
        currentMode: PowerMode? = nil,
        enabled: Bool,
        highTemp: Float,
        lowTemp: Float,
        warning: String? = nil,
        powerSource: PowerSourceState = .unknown
    ) {
        self.currentMode = currentMode
        self.enabled = enabled
        self.highTemp = highTemp
        self.lowTemp = lowTemp
        self.warning = warning
        self.powerSource = powerSource
    }
}

// MARK: - Controller

public final class PowerModeController: @unchecked Sendable {
    private let backend: PowerModeBackend
    private let queue = DispatchQueue(label: "com.thermalforge.powermode")
    private let lock = NSLock()

    /// Minimum wall-clock gap between two set attempts. Real transitions are
    /// minutes apart (thermal mass + 18° hysteresis); this is purely a storm
    /// guard against a pathological set/verify loop. Injectable for tests.
    private let minSetInterval: TimeInterval

    private var config: PowerModeConfig
    private var currentMode: PowerMode?
    private var pending: PowerMode?
    private var lastSetAt: Date?
    private var setBackoffUntil: Date?
    /// pmset ran cleanly but never reported the key — protection can't work
    /// on this system; stop attempting sets and warn once.
    private var sawKeyAbsent = false
    private var readFailed = false
    private var lastWarning: String?
    /// Power source of the last `refresh()` read. A change invalidates any
    /// lingering power-mode warning: it was issued against the *previous*
    /// power state (e.g. "requested High on AC" — meaningless once the user
    /// unplugs, because on battery the active value is the battery domain).
    private var lastKnownSource: PowerSourceState = .unknown
    /// Mode of the last *successful* set. The 2s refresh clears a lingering
    /// warning as soon as the system actually reports this value — otherwise
    /// a mismatch warning stuck around until the next set (field bug
    /// 2026-09-17: a banner for over an hour on a cool machine on battery).
    private var lastRequested: PowerMode?
    /// Re-read delay after a mismatch read-back (pmset can take a moment to
    /// apply; one retry only). Injectable for tests.
    private let verifyRetryDelay: TimeInterval

    /// Fired (on the controller queue) after any state change. The app hops
    /// to the main actor from there.
    public var onStateChange: (@Sendable (PowerModeControllerState) -> Void)?

    public init(
        backend: PowerModeBackend,
        config: PowerModeConfig = .default,
        minSetInterval: TimeInterval = 2,
        verifyRetryDelay: TimeInterval = 0.5
    ) {
        self.backend = backend
        self.config = config
        self.minSetInterval = minSetInterval
        self.verifyRetryDelay = verifyRetryDelay
    }

    // MARK: Caller-driven cadence

    /// 100ms tick — the decision. Cheap; runs on the controller queue.
    /// - peakTemp: the hottest of ALL reported sensors this tick.
    public func evaluate(peakTemp: Float?) {
        queue.async { [self] in tick(peakTemp: peakTemp) }
    }

    /// 2s tick — re-read the ACTUAL system mode. This is what kills the v1
    /// stale-state bug: if anything external flips the mode (a manual pmset,
    /// a reboot…), the controller converges on the truth within 2s instead
    /// of trusting a local variable that may be wrong.
    public func refreshMode() {
        queue.async { [self] in refresh() }
    }

    /// GUI — apply a new configuration (re-validated) and publish. The next
    /// 100ms tick acts on it; no set is issued here on purpose.
    public func update(config newConfig: PowerModeConfig) {
        queue.async { [self] in
            var validated = newConfig
            validated.validate()
            config = validated
            publish()
        }
    }

    /// Thread-safe snapshot for synchronous callers (launch, tests).
    public var state: PowerModeControllerState {
        queue.sync { makeState() }
    }

    // MARK: Decision

    /// The pure decision — which mode the system SHOULD be in, or nil for
    /// "no change". Asymmetric on purpose, because this is a safety function:
    /// - danger zone (≥ high): assert reduced even when the current mode is
    ///   UNKNOWN — re-asserting reduced is idempotent and harmless.
    /// - cooling (≤ low): restore high ONLY when we last verified reduced —
    ///   never blindly, since an unknown current mode may be throttling for
    ///   a reason we can't see. And NEVER on battery (user safety floor): on
    ///   battery the system stays reduced until it is back on AC.
    static func requiredMode(
        peakTemp: Float?,
        current: PowerMode?,
        config: PowerModeConfig,
        powerSource: PowerSourceState = .unknown
    ) -> PowerMode? {
        guard config.enabled, let temp = peakTemp else { return nil }
        if temp >= config.highTemp {
            return current == .reduced ? nil : .reduced
        }
        if temp <= config.lowTemp {
            guard current == .reduced else { return nil }
            // On battery: stay reduced. High returns only after AC.
            return powerSource == .battery ? nil : .high
        }
        return nil   // inside the hysteresis band: leave it alone
    }

    // MARK: Ticks

    private func tick(peakTemp: Float?) {
        guard let target = Self.requiredMode(
            peakTemp: peakTemp,
            current: currentMode,
            config: config,
            powerSource: backend.lastPowerSource
        ),
              let temp = peakTemp
        else { return }
        guard target != pending else { return }
        guard !sawKeyAbsent else { return }   // verified: no powermode key on this system
        guard canSet() else { return }
        performSet(target, reason: "peak \(Self.format(temp))°C")
    }

    private func refresh() {
        switch backend.readResult() {
        case .mode(let mode):
            readFailed = false
            // Power source changed (unplug/re-plug): a lingering warning was
            // issued against the previous power state and no longer applies.
            var stateChanged = false
            if backend.lastPowerSource != lastKnownSource {
                lastKnownSource = backend.lastPowerSource
                stateChanged = true
                TFLogger.shared.power("Power source → \(lastKnownSource.label)")
                if lastWarning != nil {
                    clearWarning()
                }
            }
            // Warning lifecycle: once the system reports the mode of our last
            // successful request, a lingering mismatch warning is stale —
            // clear it here (previously it stuck around until the next set).
            if mode == lastRequested {
                clearWarning()
                stateChanged = true
            }
            if mode != currentMode {
                currentMode = mode
                stateChanged = true
                TFLogger.shared.power(
                    "Detected external power mode change — now \(mode.displayName) (\(backend.lastPowerSource.label))"
                )
            }
            if stateChanged { publish() }
        case .unknownValue(let raw):
            readFailed = false
            // A mode Apple gave us a number for but no meaning: treat as
            // "not verified reduced". The decision rules then only ever act
            // in the safe direction (assert reduced in the danger zone).
            if currentMode != nil {
                currentMode = nil
                setWarning("pmset reports powermode \(raw) — unrecognized; protection will only act in the reduced direction")
                publish()
            }
        case .keyAbsent:
            readFailed = false
            if !sawKeyAbsent {
                sawKeyAbsent = true
                currentMode = nil
                setWarning("pmset on this system has no powermode key — overheat protection is unavailable")
                TFLogger.shared.power("powermode key absent from pmset -g — disabling protection")
                publish()
            }
        case .failed(let detail):
            // Transient pmset hiccup: keep the last known value, no state
            // change, no warning churn. The next 2s refresh retries.
            // Log once per failure STREAK, not every 2s.
            if !readFailed {
                TFLogger.shared.power("power mode read failed (will retry): \(detail)")
            }
            readFailed = true
        }
    }

    // MARK: Set + verify

    private func canSet() -> Bool {
        guard pending == nil else { return false }
        let now = Date()
        if let backoff = setBackoffUntil, now < backoff { return false }
        if let last = lastSetAt, now.timeIntervalSince(last) < minSetInterval { return false }
        return true
    }

    private func performSet(_ target: PowerMode, reason: String) {
        pending = target
        lastSetAt = Date()
        defer { pending = nil }

        // Target the domain the system is drawing from: an AC-only (`-c`) set
        // is invisible to the effective read while on battery (field bug
        // 2026-09-17: ~1 h of false mismatches on a cool machine on battery).
        let domain = backend.lastPowerSource == .battery ? PowerDomain.battery : .ac
        do {
            try backend.setMode(target, in: domain)
        } catch {
            setBackoffUntil = Date().addingTimeInterval(30)
            // Use CustomStringConvertible's description, not localizedDescription
            // — the latter gives generic boilerplate for plain Swift errors,
            // swallowing the real diagnostic (e.g. the sudo failure detail).
            let detail = String(describing: error)
            setWarning(detail)
            TFLogger.shared.power("SET FAILED (\(reason)): \(detail)")
            publish()
            return
        }

        lastRequested = target
        // Read-back verify — never trust a fire-and-forget set.
        switch backend.readResult() {
        case .mode(let actual) where actual == target:
            currentMode = target
            setBackoffUntil = nil
            clearWarning()
            TFLogger.shared.power(
                "Power mode → \(target.displayName) (\(reason)), verified"
            )
        case .mode(let actual):
            currentMode = actual
            setBackoffUntil = Date().addingTimeInterval(30)
            setWarning("Power mode set to \(target.displayName) but the system reports \(actual.displayName)")
            TFLogger.shared.power(
                "VERIFY MISMATCH: requested \(target.displayName), system reports \(actual.displayName) (\(reason), \(backend.lastPowerSource.label))"
            )
            // One retry: pmset can take a moment to apply, and a stale
            // read-back would otherwise leave the warning standing until the
            // next set (observed 2026-09-17, reduced direction).
            queue.asyncAfter(deadline: .now() + verifyRetryDelay) { [self] in
                self.retryVerify(target: target)
            }
        case .keyAbsent:
            sawKeyAbsent = true
            setBackoffUntil = Date().addingTimeInterval(30)
            setWarning("pmset rejected the powermode setting on this system")
            TFLogger.shared.power("set reported key absent — disabling protection")
        case .unknownValue(let raw):
            // The set was accepted but the read-back holds a value we don't
            // understand — unverifiable. Don't trust it, and let the decision
            // rules act only in the safe direction from here.
            currentMode = nil
            setBackoffUntil = Date().addingTimeInterval(30)
            setWarning("Power mode set to \(target.displayName) but the system reports an unrecognized mode (\(raw))")
            TFLogger.shared.power(
                "VERIFY: requested \(target.displayName), system reports unrecognized mode \(raw) (\(reason))"
            )
        case .failed:
            // The set itself succeeded; only the verification read hiccuped.
            // Trust the set, keep retrying the read via the 2s refresh.
            currentMode = target
            TFLogger.shared.power(
                "Power mode → \(target.displayName) (\(reason)); verification read failed, will re-verify"
            )
        }
        publish()
    }

    /// The one post-mismatch re-read (scheduled from `performSet`). If the
    /// system now reports the requested mode, the mismatch was an apply-lag
    /// race and the warning is cleared; otherwise it stands.
    private func retryVerify(target: PowerMode) {
        guard lastWarning != nil else { return }   // a newer outcome already resolved it
        switch backend.readResult() {
        case .mode(let actual) where actual == target:
            currentMode = actual
            clearWarning()
            TFLogger.shared.power("VERIFY MISMATCH self-resolved: now \(actual.displayName) (\(backend.lastPowerSource.label))")
            publish()
        default:
            break   // genuinely non-compliant (or still applying) — warning stands
        }
    }

    // MARK: State plumbing

    private func makeState() -> PowerModeControllerState {
        PowerModeControllerState(
            currentMode: currentMode,
            enabled: config.enabled,
            highTemp: config.highTemp,
            lowTemp: config.lowTemp,
            warning: lastWarning,
            powerSource: backend.lastPowerSource
        )
    }

    private func setWarning(_ message: String) {
        lastWarning = message
    }

    private func clearWarning() {
        lastWarning = nil
    }

    private func publish() {
        onStateChange?(makeState())
    }

    private static func format(_ temp: Float) -> String {
        String(format: "%.1f", temp)
    }
}
