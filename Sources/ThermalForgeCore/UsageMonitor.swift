//
//  UsageMonitor.swift
//  ThermalForge
//
//  GPU and Neural Engine utilization via IOReport.
//  Samples the "Energy Model" IOReport group which contains
//  per-domain residency counters for GPU, ANE, CPU clusters, etc.
//
//  Approach: two consecutive samples with a short interval; compute
//  delta active / delta total for each domain → utilization %.
//
//  Sources:
//  - https://github.com/nicowillis/IOReport (MIT)
//  - powermetrics source (Apple Open Source)
//  - IOReport.h (private framework, reverse-engineered)
//

import Foundation
import IOKit

// MARK: - IOReport C Shims

private typealias IOReportSubscriptionCreate_t = @convention(c) (
    CFDictionary?, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt32
) -> Unmanaged<CFTypeRef>?

private typealias IOReportCreateSamples_t = @convention(c) (
    CFTypeRef, CFMutableDictionary, CFDictionary?
) -> Unmanaged<CFDictionary>?

private typealias IOReportCreateSamplesDelta_t = @convention(c) (
    CFDictionary, CFDictionary, CFDictionary?
) -> Unmanaged<CFDictionary>?

private typealias IOReportChannelGetGroup_t        = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
private typealias IOReportChannelGetChannelName_t  = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
private typealias IOReportStateGetCount_t          = @convention(c) (CFDictionary) -> Int32
private typealias IOReportStateGetNameForIndex_t   = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
private typealias IOReportStateGetResidency_t      = @convention(c) (CFDictionary, Int32) -> Int64
private typealias IOReportCopySamplesByGroup_t     = @convention(c) (CFDictionary) -> Unmanaged<CFArray>?
private typealias IOReportCopyChannelsInGroup_t    = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?

// MARK: - UsageSnapshot

public struct UsageSnapshot {
    public let gpuPercent: Double?
    public let anePercent: Double?
    public static let unavailable = UsageSnapshot(gpuPercent: nil, anePercent: nil)
}

// MARK: - UsageMonitor

public final class UsageMonitor {

    public static let shared = UsageMonitor()

    private var subscription: CFTypeRef?
    private var subbedChannels: CFMutableDictionary?
    private var previousSample: CFDictionary?
    private var isAvailable: Bool = false

    private var fnCreate:       IOReportSubscriptionCreate_t?
    private var fnSamples:      IOReportCreateSamples_t?
    private var fnDelta:        IOReportCreateSamplesDelta_t?
    private var fnGetGroup:     IOReportChannelGetGroup_t?
    private var fnGetName:      IOReportChannelGetChannelName_t?
    private var fnGetCount:     IOReportStateGetCount_t?
    private var fnGetStateName: IOReportStateGetNameForIndex_t?
    private var fnGetResidency: IOReportStateGetResidency_t?
    private var fnCopyByGroup:  IOReportCopySamplesByGroup_t?
    private var fnCopyChannels: IOReportCopyChannelsInGroup_t?

    private init() {
        let fw1 = "/System/Library/PrivateFrameworks/IOReporter.framework/IOReporter"
        let fw2 = "/System/Library/PrivateFrameworks/IOReporter.framework/Versions/A/IOReporter"
        guard let handle = dlopen(fw1, RTLD_NOW) ?? dlopen(fw2, RTLD_NOW) else {
            TFLogger.shared.info("UsageMonitor: IOReporter not available — GPU/ANE utilization disabled")
            return
        }

        fnCreate       = sym(handle, "IOReportSubscriptionCreate")
        fnSamples      = sym(handle, "IOReportCreateSamples")
        fnDelta        = sym(handle, "IOReportCreateSamplesDelta")
        fnGetGroup     = sym(handle, "IOReportChannelGetGroup")
        fnGetName      = sym(handle, "IOReportChannelGetChannelName")
        fnGetCount     = sym(handle, "IOReportStateGetCount")
        fnGetStateName = sym(handle, "IOReportStateGetNameForIndex")
        fnGetResidency = sym(handle, "IOReportStateGetResidency")
        fnCopyByGroup  = sym(handle, "IOReportCopySamplesByChannel")
        fnCopyChannels = sym(handle, "IOReportCopyChannelsInGroup")

        guard fnCreate != nil, fnSamples != nil, fnDelta != nil else {
            TFLogger.shared.info("UsageMonitor: IOReport symbols missing")
            return
        }

        isAvailable = setupSubscription()
        if isAvailable {
            TFLogger.shared.info("UsageMonitor: IOReport subscription active")
        }
    }

    private func sym<T>(_ handle: UnsafeMutableRawPointer, _ name: String) -> T? {
        guard let ptr = dlsym(handle, name) else { return nil }
        return unsafeBitCast(ptr, to: T?.self)
    }

    // MARK: - Setup

    private func setupSubscription() -> Bool {
        guard let fnCopyChannels = fnCopyChannels,
              let fnCreate = fnCreate else { return false }

        guard let channelsRef = fnCopyChannels("Energy Model" as CFString, nil, 0, 0, 0) else {
            TFLogger.shared.info("UsageMonitor: could not get Energy Model channels")
            return false
        }
        let channels = channelsRef.takeRetainedValue()

        var subbedRef: Unmanaged<CFMutableDictionary>? = nil
        guard let subRef = fnCreate(channels, &subbedRef, 0) else { return false }
        subscription = subRef.takeRetainedValue()

        guard let subbed = subbedRef?.takeRetainedValue() else { return false }
        subbedChannels = subbed
        return true
    }

    // MARK: - Sampling

    public func sample() -> UsageSnapshot? {
        guard isAvailable,
              let sub = subscription,
              let subbed = subbedChannels,
              let fnSamples = fnSamples,
              let fnDelta = fnDelta else {
            return UsageSnapshot.unavailable
        }

        guard let currentRef = fnSamples(sub, subbed, nil) else { return nil }
        let current = currentRef.takeRetainedValue()
        defer { previousSample = current }

        guard let prev = previousSample else { return nil }

        guard let deltaRef = fnDelta(prev, current, nil) else { return nil }
        return parseUsage(from: deltaRef.takeRetainedValue())
    }

    // MARK: - Parsing

    private func parseUsage(from delta: CFDictionary) -> UsageSnapshot {
        guard let fnCopyByGroup   = fnCopyByGroup,
              let fnGetGroup      = fnGetGroup,
              let fnGetName       = fnGetName,
              let fnGetCount      = fnGetCount,
              let fnGetStateName  = fnGetStateName,
              let fnGetResidency  = fnGetResidency else { return .unavailable }

        guard let channelsRef = fnCopyByGroup(delta) else { return .unavailable }
        let channels = channelsRef.takeRetainedValue() as? [CFDictionary] ?? []

        var gpuActive: Int64 = 0; var gpuTotal: Int64 = 0
        var aneActive: Int64 = 0; var aneTotal: Int64 = 0

        for ch in channels {
            guard let grpRef  = fnGetGroup(ch),
                  let nameRef = fnGetName(ch) else { continue }
            let group = grpRef.takeUnretainedValue() as String
            let name  = nameRef.takeUnretainedValue() as String
            guard group == "Energy Model" else { continue }

            let isGPU = name.hasPrefix("GPU")
            let isANE = name.hasPrefix("ANE")
            guard isGPU || isANE else { continue }

            let count = fnGetCount(ch)
            for i in 0..<count {
                let residency  = fnGetResidency(ch, i)
                let stateStr   = fnGetStateName(ch, i)?.takeUnretainedValue() as String? ?? ""
                let isActive   = stateStr.uppercased().contains("ACTIVE")
                if isGPU { gpuTotal += residency; if isActive { gpuActive += residency } }
                else      { aneTotal += residency; if isActive { aneActive += residency } }
            }
        }

        let gpuPct: Double? = gpuTotal > 0 ? Double(gpuActive) / Double(gpuTotal) * 100 : nil
        let anePct: Double? = aneTotal > 0 ? Double(aneActive) / Double(aneTotal) * 100 : nil
        return UsageSnapshot(gpuPercent: gpuPct, anePercent: anePct)
    }
}
