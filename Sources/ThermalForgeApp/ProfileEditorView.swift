//
//  ProfileEditorView.swift
//  ThermalForge
//
//  In-app Custom Profile editor (rq.md §16): Temperature/Fan% curve points with
//  Add/Edit/Move/Delete, 0-2 sensor conditions with AND/OR, and the governor knobs
//  (ramp up/down, sustained trigger, max fan %). Saves through the same
//  `FanProfile.custom(...)` + `.save()` path the CLI's `profile save` uses, so a
//  profile created in either place is usable in the other.
//

import SwiftUI
import ThermalForgeCore

/// One curve point being edited. A local, `Identifiable` copy of `FanCurvePoint` —
/// SwiftUI needs stable per-row identity while the user is mid-edit (e.g. has
/// temporarily typed a duplicate temperature), which the validated `FanCurvePoint`
/// itself doesn't provide.
private struct EditablePoint: Identifiable {
    let id = UUID()
    var temperature: Double
    var fanPercent: Double
}

/// One sensor condition being edited — see `EditablePoint` for why this isn't just
/// `SensorCondition` directly.
private struct EditableCondition: Identifiable {
    let id = UUID()
    var sensor: Sensor
    var comparison: ComparisonOperator
    var threshold: Double
}

/// Window content: resolves `AppState.profileEditorTarget` to a profile (or a blank
/// new one) and hosts the actual editor. Kept separate from `ProfileEditorView` so
/// that view's `@State` is (re)initialized fresh via `.id(target)` whenever the
/// target changes, instead of stale fields surviving a New → Edit switch.
struct ProfileEditorWindow: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let target = appState.profileEditorTarget ?? .new
        ProfileEditorView(target: target)
            .id(target.id)
            .environmentObject(appState)
    }
}

struct ProfileEditorView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let target: ProfileEditorTarget

    @State private var name: String
    @State private var idText: String
    @State private var isNew: Bool
    @State private var points: [EditablePoint]
    @State private var conditions: [EditableCondition]
    @State private var conditionOperator: ConditionOperator
    @State private var rampUpPerSec: Double
    @State private var rampDownPerSec: Double
    @State private var sustainedTriggerSec: Double
    @State private var maxPercent: Double
    @State private var errorMessage: String?

    init(target: ProfileEditorTarget) {
        self.target = target
        let existing: FanProfile? = {
            guard case .edit(let id) = target else { return nil }
            return FanProfile.loadAll().first { $0.id == id }
        }()

        _isNew = State(initialValue: existing == nil)
        _name = State(initialValue: existing?.name ?? "")
        _idText = State(initialValue: existing?.id ?? "")
        if let curvePoints = existing?.customCurve?.points, !curvePoints.isEmpty {
            _points = State(initialValue: curvePoints.map {
                EditablePoint(temperature: Double($0.temperature), fanPercent: Double($0.fanPercent))
            })
        } else {
            _points = State(initialValue: [
                EditablePoint(temperature: 50, fanPercent: 0),
                EditablePoint(temperature: 75, fanPercent: 100),
            ])
        }
        _conditions = State(initialValue: (existing?.sensorConditions ?? []).map {
            EditableCondition(sensor: $0.sensor, comparison: $0.comparison, threshold: Double($0.threshold))
        })
        _conditionOperator = State(initialValue: existing?.conditionOperator ?? .and)
        _rampUpPerSec = State(initialValue: Double(existing?.curve.rampUpPerSec ?? 0.05))
        _rampDownPerSec = State(initialValue: Double(existing?.curve.rampDownPerSec ?? 0.025))
        _sustainedTriggerSec = State(initialValue: Double(existing?.curve.sustainedTriggerSec ?? 8))
        _maxPercent = State(initialValue: Double(existing?.curve.maxRPMPercent ?? 1.0) * 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Custom Profile" : "Edit Custom Profile")
                .font(.title2.bold())

            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                    TextField("ID", text: $idText)
                        .disabled(!isNew)
                        .help("Used as the filename and for --profile lookups. Can't be changed after creation — save as a new id instead.")
                }

                Section("Curve — Temperature → Fan %") {
                    ForEach(Array(points.enumerated()), id: \.element.id) { index, _ in
                        HStack {
                            TextField("°C", value: $points[index].temperature, format: .number)
                                .frame(width: 56)
                            Text("→")
                                .foregroundStyle(.secondary)
                            TextField("%", value: $points[index].fanPercent, format: .number)
                                .frame(width: 56)
                            Text("%")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                points.swapAt(index, index - 1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .disabled(index == 0)
                            Button {
                                points.swapAt(index, index + 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .disabled(index == points.count - 1)
                            Button(role: .destructive) {
                                points.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .disabled(points.count <= 1)
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        let last = points.last
                        points.append(EditablePoint(
                            temperature: (last?.temperature ?? 50) + 5,
                            fanPercent: last?.fanPercent ?? 50
                        ))
                    } label: {
                        Label("Add Point", systemImage: "plus.circle")
                    }
                }

                Section("Sensor Conditions — up to 2") {
                    ForEach(Array(conditions.enumerated()), id: \.element.id) { index, _ in
                        HStack {
                            Picker("", selection: $conditions[index].sensor) {
                                ForEach(Sensor.allCases, id: \.self) { sensor in
                                    Text(sensor.displayName).tag(sensor)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 80)
                            Picker("", selection: $conditions[index].comparison) {
                                Text(">").tag(ComparisonOperator.greaterThan)
                                Text(">=").tag(ComparisonOperator.greaterThanOrEqual)
                                Text("<").tag(ComparisonOperator.lessThan)
                                Text("<=").tag(ComparisonOperator.lessThanOrEqual)
                            }
                            .labelsHidden()
                            .frame(width: 60)
                            TextField("°C", value: $conditions[index].threshold, format: .number)
                                .frame(width: 56)
                            Spacer()
                            Button(role: .destructive) {
                                conditions.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if conditions.count == 2 {
                        Picker("Combine with", selection: $conditionOperator) {
                            Text("AND").tag(ConditionOperator.and)
                            Text("OR").tag(ConditionOperator.or)
                        }
                        .pickerStyle(.segmented)
                    }
                    if conditions.count < 2 {
                        Button {
                            conditions.append(EditableCondition(sensor: .cpu, comparison: .greaterThanOrEqual, threshold: 70))
                        } label: {
                            Label("Add Condition", systemImage: "plus.circle")
                        }
                    } else {
                        Text("Conditions gate the profile: fans follow the curve only while they're satisfied — otherwise fans stay off, same as the curve saying off.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Advanced") {
                    LabeledContent("Max fan speed") {
                        HStack {
                            Slider(value: $maxPercent, in: 10...100, step: 1)
                            Text("\(Int(maxPercent))%").frame(width: 44, alignment: .trailing)
                        }
                    }
                    LabeledContent("Ramp up") {
                        HStack {
                            Slider(value: $rampUpPerSec, in: 0.01...1.0)
                            Text(String(format: "%.2f/s", rampUpPerSec)).frame(width: 44, alignment: .trailing)
                        }
                    }
                    LabeledContent("Ramp down") {
                        HStack {
                            Slider(value: $rampDownPerSec, in: 0.01...1.0)
                            Text(String(format: "%.2f/s", rampDownPerSec)).frame(width: 44, alignment: .trailing)
                        }
                    }
                    LabeledContent("Sustained trigger") {
                        HStack {
                            Slider(value: $sustainedTriggerSec, in: 0...30, step: 1)
                            Text("\(Int(sustainedTriggerSec))s").frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { delete() }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: - Actions

    private func save() {
        let id = idText.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else {
            errorMessage = "ID can't be empty."
            return
        }

        do {
            // Sort by temperature before validating — reordering with the chevrons is
            // a convenience, not a requirement the user must get exactly right by hand.
            let sortedPoints = points.sorted { $0.temperature < $1.temperature }
            let curvePoints = sortedPoints.map {
                FanCurvePoint(temperature: Float($0.temperature), fanPercent: Float($0.fanPercent))
            }
            let customCurve = try CustomCurve(points: curvePoints)

            let sensorConditions = conditions.map {
                SensorCondition(sensor: $0.sensor, comparison: $0.comparison, threshold: Float($0.threshold))
            }
            let op: ConditionOperator? = sensorConditions.count == 2 ? conditionOperator : nil

            let profile = try FanProfile.custom(
                id: id, name: name.isEmpty ? id : name, customCurve: customCurve,
                sensorConditions: sensorConditions, conditionOperator: op,
                rampUpPerSec: Float(rampUpPerSec), rampDownPerSec: Float(rampDownPerSec),
                sustainedTriggerSec: Float(sustainedTriggerSec), maxRPMPercent: Float(maxPercent / 100)
            )
            try profile.save()
            TFLogger.shared.profile("Custom Profile saved: \(profile.name) (\(profile.id))")
            dismiss()
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func delete() {
        guard case .edit(let id) = target else { return }
        do {
            try FanProfile.delete(id: id)
            TFLogger.shared.profile("Custom Profile deleted: \(id)")
            dismiss()
        } catch {
            errorMessage = "Couldn't delete: \(error.localizedDescription)"
        }
    }
}
