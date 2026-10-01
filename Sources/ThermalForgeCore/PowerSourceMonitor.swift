//
//  PowerSourceMonitor.swift
//  ThermalForge
//
//  Notification-driven power-source tracking (AC ↔ battery) via IOKit.
//
//  One initial query, then a CFRunLoop source that fires when power-source
//  information changes: no polling, no pmset subprocess for the source.
//  (pmset is still used for the power *mode* itself — source and mode are
//  different things; the source only decides the set domain, the battery
//  rule, and the UI glyph.)
//
//  Apple documents the notification as deliberately BROADER than an AC↔
//  battery flip — it also fires on battery percent / time-remaining changes
//  — so `updatePowerSource()` re-queries and only invokes `onChange` when
//  the *providing source type* actually changed.
//
//  The callback may run on any thread (in practice the run loop's); the
//  pmset backend stores the result under a lock because the controller
//  reads the source on its own serial queue.
//

import Foundation
import IOKit.ps

/// Tracks where the system is currently drawing power from and reports real
/// changes through `onChange`. Receives one call for the initial state,
/// then one per actual unplug/re-plug.
public final class PowerSourceMonitor {
    /// Called with the new source whenever the providing power source
    /// actually changes. May run on any thread — receivers must synchronize.
    public var onChange: (@Sendable (PowerSourceState) -> Void)?

    private var runLoopSource: CFRunLoopSource?
    private var currentSource: PowerSourceState = .unknown

    public init() {}

    /// Query the initial state and register the change notification. Call
    /// once, from the main thread — the source is attached to the main run
    /// loop, which a menu-bar app always runs.
    public func start() {
        updatePowerSource()

        // The macOS 27 IOKit signature: the callback takes a single user
        // pointer (no context struct) and is an @convention(c) function.
        let context = Unmanaged.passUnretained(self).toOpaque()
        runLoopSource = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context else { return }
                let monitor = Unmanaged<PowerSourceMonitor>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                monitor.updatePowerSource()
            },
            context
        )?.takeRetainedValue()

        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
    }

    private func updatePowerSource() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return }
        // `takeRetainedValue()` hands the +1 retain to ARC — the `info`
        // dictionary is released automatically when this scope ends.

        // `IOPSGetProvidingPowerSourceType` yields a CFString; the kIOPS*
        // constants import as Swift String in this SDK — bridge and compare.
        let providing = type as String
        let newSource: PowerSourceState
        if providing == kIOPSACPowerValue || providing == kIOPMUPSPowerKey {
            // A UPS is an unlimited external source — for the guard's
            // purposes (restore-high allowed) it is AC-equivalent.
            newSource = .ac
        } else if providing == kIOPSBatteryPowerValue {
            newSource = .battery
        } else {
            newSource = .unknown
        }

        guard newSource != currentSource else { return }
        currentSource = newSource
        onChange?(newSource)
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
    }
}
