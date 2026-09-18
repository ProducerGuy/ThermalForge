//
//  SensorConditionTests.swift
//  ThermalForge
//
//  rq.md §18 — Dual Sensor Condition: single condition, AND, OR, and the §10 sensor
//  failure fallback (an unavailable sensor must never be misread as 0°C).
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("SensorCondition")
struct SensorConditionTests {
    func status(cpu: Float?, gpu: Float?) -> ThermalStatus {
        var temps: [String: Float] = [:]
        if let cpu { temps["TC0P"] = cpu }
        if let gpu { temps["TG0P"] = gpu }
        return ThermalStatus(fans: [], temperatures: temps)
    }

    @Test("single CPU >= 70 condition")
    func singleCondition() {
        let cond = SensorCondition(sensor: .cpu, comparison: .greaterThanOrEqual, threshold: 70)
        #expect(SensorConditionEvaluator.isSatisfied([cond], operator: nil, in: status(cpu: 69, gpu: nil)) == false)
        #expect(SensorConditionEvaluator.isSatisfied([cond], operator: nil, in: status(cpu: 70, gpu: nil)) == true)
        #expect(SensorConditionEvaluator.isSatisfied([cond], operator: nil, in: status(cpu: 71, gpu: nil)) == true)
    }

    @Test("0 conditions is always satisfied — matches every built-in profile's behavior")
    func zeroConditions() {
        #expect(SensorConditionEvaluator.isSatisfied([], operator: nil, in: status(cpu: nil, gpu: nil)) == true)
    }

    // CPU >= 70 AND GPU >= 60
    @Test("AND: both must hold", arguments: [
        (Float(69), Float(59), false),
        (Float(70), Float(59), false),
        (Float(69), Float(60), false),
        (Float(70), Float(60), true),
    ])
    func andCombination(cpu: Float, gpu: Float, expected: Bool) {
        let conditions = [
            SensorCondition(sensor: .cpu, comparison: .greaterThanOrEqual, threshold: 70),
            SensorCondition(sensor: .gpu, comparison: .greaterThanOrEqual, threshold: 60),
        ]
        #expect(SensorConditionEvaluator.isSatisfied(conditions, operator: .and, in: status(cpu: cpu, gpu: gpu)) == expected)
    }

    // CPU >= 70 OR GPU >= 60
    @Test("OR: either may hold", arguments: [
        (Float(69), Float(59), false),
        (Float(70), Float(59), true),
        (Float(69), Float(60), true),
        (Float(70), Float(60), true),
    ])
    func orCombination(cpu: Float, gpu: Float, expected: Bool) {
        let conditions = [
            SensorCondition(sensor: .cpu, comparison: .greaterThanOrEqual, threshold: 70),
            SensorCondition(sensor: .gpu, comparison: .greaterThanOrEqual, threshold: 60),
        ]
        #expect(SensorConditionEvaluator.isSatisfied(conditions, operator: .or, in: status(cpu: cpu, gpu: gpu)) == expected)
    }

    @Test("all four comparison operators")
    func comparisons() {
        #expect(ComparisonOperator.greaterThan.evaluate(5, 4))
        #expect(!ComparisonOperator.greaterThan.evaluate(4, 4))
        #expect(ComparisonOperator.greaterThanOrEqual.evaluate(4, 4))
        #expect(ComparisonOperator.lessThan.evaluate(3, 4))
        #expect(!ComparisonOperator.lessThan.evaluate(4, 4))
        #expect(ComparisonOperator.lessThanOrEqual.evaluate(4, 4))
    }

    // MARK: - Sensor failure (rq.md §10)

    @Test("an unavailable sensor is never misread as 0°C")
    func unavailableSensorIsNil() {
        let cond = SensorCondition(sensor: .gpu, comparison: .greaterThanOrEqual, threshold: 60)
        // No GPU reading in the status at all (e.g. a GPU-less Mac, or a dropped read).
        #expect(cond.isSatisfied(in: status(cpu: 80, gpu: nil)) == nil)
    }

    @Test("a single-condition gate fails safe (not satisfied) when its sensor is unavailable")
    func singleConditionUnavailableSensor() {
        let cond = SensorCondition(sensor: .gpu, comparison: .greaterThanOrEqual, threshold: 60)
        #expect(SensorConditionEvaluator.isSatisfied([cond], operator: nil, in: status(cpu: 80, gpu: nil)) == false)
    }

    @Test("AND with one sensor unavailable can't be proven true")
    func andWithUnavailableSensor() {
        let conditions = [
            SensorCondition(sensor: .cpu, comparison: .greaterThanOrEqual, threshold: 70),
            SensorCondition(sensor: .gpu, comparison: .greaterThanOrEqual, threshold: 60),
        ]
        // CPU well above its threshold, but GPU has no reading at all.
        #expect(SensorConditionEvaluator.isSatisfied(conditions, operator: .and, in: status(cpu: 90, gpu: nil)) == false)
    }

    @Test("OR with one sensor unavailable still trusts the other")
    func orWithUnavailableSensor() {
        let conditions = [
            SensorCondition(sensor: .cpu, comparison: .greaterThanOrEqual, threshold: 70),
            SensorCondition(sensor: .gpu, comparison: .greaterThanOrEqual, threshold: 60),
        ]
        // GPU unavailable, but CPU alone satisfies the OR.
        #expect(SensorConditionEvaluator.isSatisfied(conditions, operator: .or, in: status(cpu: 90, gpu: nil)) == true)
        // Neither available — can't be satisfied.
        #expect(SensorConditionEvaluator.isSatisfied(conditions, operator: .or, in: status(cpu: nil, gpu: nil)) == false)
    }

    @Test("2 conditions with no operator is never satisfied")
    func missingOperator() {
        let conditions = [
            SensorCondition(sensor: .cpu, comparison: .greaterThanOrEqual, threshold: 70),
            SensorCondition(sensor: .gpu, comparison: .greaterThanOrEqual, threshold: 60),
        ]
        #expect(SensorConditionEvaluator.isSatisfied(conditions, operator: nil, in: status(cpu: 90, gpu: 90)) == false)
    }

    @Test("round-trips through JSON")
    func jsonRoundTrip() throws {
        let cond = SensorCondition(sensor: .cpu, comparison: .greaterThanOrEqual, threshold: 70)
        let data = try JSONEncoder().encode(cond)
        let decoded = try JSONDecoder().decode(SensorCondition.self, from: data)
        #expect(decoded == cond)
    }
}
