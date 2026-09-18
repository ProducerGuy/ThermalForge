//
//  SensorTests.swift
//  ThermalForge
//
//  `Sensor` reads the same CPU/GPU peak-temperature grouping ThermalStatus.safetyPeakTemp
//  and the menu bar use — this locks in that it stays in sync, and the rq.md §10 rule
//  that an unavailable sensor reads as nil, never 0°C.
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Sensor")
struct SensorTests {
    func status(cpu: Float?, gpu: Float?) -> ThermalStatus {
        var temps: [String: Float] = [:]
        if let cpu { temps["TC0P"] = cpu }
        if let gpu { temps["TG0P"] = gpu }
        return ThermalStatus(fans: [], temperatures: temps)
    }

    @Test("reads the peak of its own key prefixes")
    func peakReading() {
        let status = ThermalStatus(fans: [], temperatures: ["TC0P": 60, "Tp01": 75, "TG0P": 50])
        #expect(Sensor.cpu.temperature(in: status) == 75)
        #expect(Sensor.gpu.temperature(in: status) == 50)
    }

    @Test("an unavailable sensor reads as nil, never misread as 0°C")
    func unavailableIsNil() {
        let status = status(cpu: 80, gpu: nil)
        #expect(Sensor.cpu.temperature(in: status) == 80)
        #expect(Sensor.gpu.temperature(in: status) == nil)
    }

    @Test("display names")
    func displayNames() {
        #expect(Sensor.cpu.displayName == "CPU")
        #expect(Sensor.gpu.displayName == "GPU")
    }
}
