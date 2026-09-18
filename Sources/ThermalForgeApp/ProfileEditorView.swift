//
//  ProfileEditorView.swift
//  ThermalForge
//
//  In-app Custom Profile editor (rq.md §16): dual-sensor curve points — each row is
//  (CPU temp, GPU temp) → Fan %, jointly interpolated (see `CustomCurve2D`) — with
//  Add/Edit/Move/Delete, plus the governor knobs (ramp up/down, sustained trigger,
//  max fan %). Saves through the same `FanProfile.custom(customCurve2D:)` + `.save()`
//  path the CLI's `profile save --curve2d` uses, so a profile created in either place
//  is usable in the other.
//

import SwiftUI
import ThermalForgeCore

/// One curve point being edited. A local, `Identifiable` copy of `FanCurvePoint2D` —
/// SwiftUI needs stable per-row identity while the user is mid-edit (e.g. has
/// temporarily typed a duplicate CPU/GPU pair), which the validated `FanCurvePoint2D`
/// itself doesn't provide.
private struct EditablePoint: Identifiable {
    let id = UUID()
    var cpuTemp: Double
    var gpuTemp: Double
    var fanPercent: Double
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
        if let curvePoints = existing?.customCurve2D?.points, !curvePoints.isEmpty {
            _points = State(initialValue: curvePoints.map {
                EditablePoint(cpuTemp: Double($0.cpuTemp), gpuTemp: Double($0.gpuTemp), fanPercent: Double($0.fanPercent))
            })
        } else {
            _points = State(initialValue: [
                EditablePoint(cpuTemp: 50, gpuTemp: 45, fanPercent: 0),
                EditablePoint(cpuTemp: 80, gpuTemp: 70, fanPercent: 100),
            ])
        }
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

                Section("Curve — CPU °C, GPU °C → Fan %") {
                    Text("Each point sets the fan % for that CPU/GPU pair; the curve blends between points by how close the current readings are to each one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(Array(points.enumerated()), id: \.element.id) { index, _ in
                        HStack(spacing: 4) {
                            temperatureField(clampedToPercentRange($points[index].cpuTemp))
                            Text("°C")
                                .foregroundStyle(.secondary)
                            Text("/")
                                .foregroundStyle(.tertiary)
                            temperatureField(clampedToPercentRange($points[index].gpuTemp))
                            Text("°C")
                                .foregroundStyle(.secondary)
                            Text("→")
                                .foregroundStyle(.secondary)
                            temperatureField(clampedToPercentRange($points[index].fanPercent))
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
                            cpuTemp: min((last?.cpuTemp ?? 50) + 5, 100),
                            gpuTemp: min((last?.gpuTemp ?? 45) + 5, 100),
                            fanPercent: last?.fanPercent ?? 50
                        ))
                    } label: {
                        Label("Add Point", systemImage: "plus.circle")
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
        .frame(width: 460)
    }

    // MARK: - Helpers

    /// A single curve-field text box: right-aligned, fixed-width, no placeholder unit
    /// text (the unit is a separate `Text` beside it — see the row layout above) so
    /// there's exactly one "°C"/"%" per field, never a duplicated one.
    @ViewBuilder
    private func temperatureField(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number)
            .frame(width: 40)
            .multilineTextAlignment(.trailing)
    }

    /// Clamps a curve point field (CPU/GPU temp or fan %) to 0...100 as it's typed,
    /// rather than only surfacing a validation error at Save. Curve points don't need
    /// headroom above 100 — fan % is capped there by definition, and Custom Profiles
    /// only govern normal operating temperatures (the 95°C emergency floor is a
    /// separate, unconditional layer above any curve — rq.md §20).
    private func clampedToPercentRange(_ value: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max($0, 0), 100) }
        )
    }

    // MARK: - Actions

    private func save() {
        let id = idText.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else {
            errorMessage = "ID can't be empty."
            return
        }

        do {
            let curvePoints = points.map {
                FanCurvePoint2D(cpuTemp: Float($0.cpuTemp), gpuTemp: Float($0.gpuTemp), fanPercent: Float($0.fanPercent))
            }
            let customCurve2D = try CustomCurve2D(points: curvePoints)

            let profile = FanProfile.custom(
                id: id, name: name.isEmpty ? id : name, customCurve2D: customCurve2D,
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
