//
//  ProfileEditorView.swift
//  ThermalForge
//
//  In-app Custom Profile editor (rq.md §16): a dual-sensor curve. The two sensors are
//  chosen ONCE at the top (any of `Sensor`'s cases — CPU/GPU/RAM/SSD/Ambient, not
//  fixed to CPU/GPU) and apply to every point; each point row is one line: both
//  readings, then the fan value. Fan is always stored as a % (0...100 — this is what
//  keeps a saved profile portable across Macs with different fan hardware), but can be
//  entered/viewed as RPM instead, converted live against this Mac's actual SMC-reported
//  min/max (see `fanRPMRange`) rather than a guessed-at-generation table.
//  Add/Edit/Move/Delete on points, plus the governor knobs (ramp up/down, sustained
//  trigger, max fan %). Saves through the same `FanProfile.custom(customCurve2D:)` +
//  `.save()` path the CLI's `profile save --curve2d` uses, so a profile created in
//  either place is usable in the other.
//

import SwiftUI
import ThermalForgeCore

/// One curve point being edited. A local, `Identifiable` copy of `FanCurvePoint2D` —
/// SwiftUI needs stable per-row identity while the user is mid-edit (e.g. has
/// temporarily typed a duplicate pair), which the validated `FanCurvePoint2D` itself
/// doesn't provide.
private struct EditablePoint: Identifiable {
    let id = UUID()
    var sensorAValue: Double
    var sensorBValue: Double
    var fanPercent: Double
    /// Menu bar icon color once the fan's actual speed reaches `fanPercent`. nil
    /// (the default) sets no color, which is the common case.
    var color: Color?
}

private extension Color {
    /// This color's sRGB components as a `PointColor`, for persistence. `NSColor`
    /// resolves against the CURRENT appearance — a one-time conversion at Save, not
    /// something that needs to track light/dark mode afterward. nil only for a color
    /// that can't be resolved to RGB at all (e.g. a pattern/catalog color, which the
    /// system `ColorPicker` never actually produces).
    var pointColor: PointColor? {
        guard let rgb = NSColor(self).usingColorSpace(.deviceRGB) else { return nil }
        return PointColor(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent))
    }
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
    @State private var sensorA: Sensor
    @State private var sensorB: Sensor
    @State private var points: [EditablePoint]
    @State private var rampUpPerSec: Double
    @State private var rampDownPerSec: Double
    @State private var sustainedTriggerSec: Double
    @State private var maxPercent: Double
    @State private var errorMessage: String?
    /// Display/entry mode for curve points' fan values. Storage is always `fanPercent`
    /// (0...100) — RPM is a view onto that, converted against this Mac's live SMC
    /// min/max, so a saved Custom Profile stays portable across machines with
    /// different fan hardware (rather than baking in one Mac's RPM numbers).
    @State private var useRPM = false

    init(target: ProfileEditorTarget) {
        self.target = target
        let existing: FanProfile? = {
            guard case .edit(let id) = target else { return nil }
            return FanProfile.loadAll().first { $0.id == id }
        }()

        _isNew = State(initialValue: existing == nil)
        _name = State(initialValue: existing?.name ?? "")
        _idText = State(initialValue: existing?.id ?? "")
        _sensorA = State(initialValue: existing?.customCurve2D?.sensorA ?? .cpu)
        _sensorB = State(initialValue: existing?.customCurve2D?.sensorB ?? .gpu)
        if let curvePoints = existing?.customCurve2D?.points, !curvePoints.isEmpty {
            _points = State(initialValue: curvePoints.map {
                EditablePoint(
                    sensorAValue: Double($0.sensorAValue), sensorBValue: Double($0.sensorBValue), fanPercent: Double($0.fanPercent),
                    color: $0.color.map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
                )
            })
        } else {
            _points = State(initialValue: [
                EditablePoint(sensorAValue: 50, sensorBValue: 45, fanPercent: 0),
                EditablePoint(sensorAValue: 80, sensorBValue: 70, fanPercent: 100),
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

                Section("Sensors") {
                    Text("Choose the two readings each curve point is defined by. Every point uses the same pair.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Sensor A", selection: $sensorA) {
                        ForEach(Sensor.allCases, id: \.self) { sensor in
                            Text(sensor.displayName).tag(sensor)
                        }
                    }
                    Picker("Sensor B", selection: $sensorB) {
                        ForEach(Sensor.allCases.filter { $0 != sensorA }, id: \.self) { sensor in
                            Text(sensor.displayName).tag(sensor)
                        }
                    }
                    .onChange(of: sensorA) { _, newValue in
                        // Sensor B's list above already excludes A; if the change made
                        // them collide, bump B to whatever's now first instead of
                        // leaving it pointing at a choice that's no longer offered.
                        if sensorB == newValue {
                            sensorB = Sensor.allCases.first { $0 != newValue } ?? sensorB
                        }
                    }
                }

                Section("Curve — \(sensorA.displayName) °C / \(sensorB.displayName) °C → Fan") {
                    Text("Each point sets the fan speed for that \(sensorA.displayName)/\(sensorB.displayName) pair; the curve blends between points by how close the current readings are to each one. Optionally color a point — the menu bar icon switches to it once the fan's actual speed reaches that point.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Fan value", selection: $useRPM) {
                        Text("%").tag(false)
                        Text("RPM").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(fanRPMRange == nil)

                    if let range = fanRPMRange {
                        Text(useRPM
                            ? "This Mac's fan range: \(range.min)–\(range.max) RPM"
                            : "This Mac's fan range: \(range.min)–\(range.max) RPM (0% and 100% map to these)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("Waiting for fan data to show the RPM range…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    ForEach(Array(points.enumerated()), id: \.element.id) { index, _ in
                        pointRow(index: index)
                        if index < points.count - 1 {
                            Divider()
                        }
                    }
                    Button {
                        let last = points.last
                        points.append(EditablePoint(
                            sensorAValue: min((last?.sensorAValue ?? 50) + 5, 100),
                            sensorBValue: min((last?.sensorBValue ?? 45) + 5, 100),
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
        .frame(width: 560)
    }

    // MARK: - Point row

    /// One curve point, all on a single line: both readings, the fan % they produce,
    /// an optional menu bar icon color for when the fan's actual speed reaches this
    /// point, and the move/delete controls.
    @ViewBuilder
    private func pointRow(index: Int) -> some View {
        HStack(spacing: 4) {
            sensorValueField(label: sensorA.displayName, value: clampedToPercentRange($points[index].sensorAValue))
            sensorValueField(label: sensorB.displayName, value: clampedToPercentRange($points[index].sensorBValue))
            Text("→")
                .foregroundStyle(.secondary)
            Text("Fan")
                .font(.caption)
                .foregroundStyle(.secondary)
            fanField(fanValueBinding(index))
            Text(useRPM ? "RPM" : "%")
                .foregroundStyle(.secondary)
            ColorPicker("", selection: colorBinding(index), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 20)
                .help("Menu bar icon color once the fan's actual speed reaches this point")
            if points[index].color != nil {
                Button {
                    points[index].color = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove this point's color")
            }
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
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func sensorValueField(label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
                .lineLimit(1)
            temperatureField(value)
            Text("°C")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    /// A single curve-field text box: right-aligned, fixed-width, no placeholder unit
    /// text (the unit is a separate `Text` beside it) so there's exactly one "°C"/"%"
    /// per field, never a duplicated one.
    @ViewBuilder
    private func temperatureField(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number)
            .frame(width: 32)
            .multilineTextAlignment(.trailing)
    }

    /// Same as `temperatureField` but wider — RPM values run up to 4 digits
    /// (e.g. 7826), unlike the 0-100 every other field holds.
    @ViewBuilder
    private func fanField(_ value: Binding<Double>) -> some View {
        TextField("", value: value, format: .number)
            .frame(width: useRPM ? 46 : 32)
            .multilineTextAlignment(.trailing)
    }

    /// Clamps a curve point field (a sensor reading or fan %) to 0...100 as it's
    /// typed, rather than only surfacing a validation error at Save. Curve points
    /// don't need headroom above 100 — fan % is capped there by definition, and
    /// Custom Profiles only govern normal operating temperatures (the 95°C emergency
    /// floor is a separate, unconditional layer above any curve — rq.md §20).
    private func clampedToPercentRange(_ value: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max($0, 0), 100) }
        )
    }

    /// This Mac's actual fan RPM range, read live from SMC via the menu bar's own
    /// status poll — not guessed from an Apple Silicon generation (M1/M2/.../M5),
    /// since even machines sharing a chip can have different fan hardware (MacBook
    /// Air vs. Pro vs. Studio). nil only until the first status poll lands (~500ms
    /// after launch), or if fan data couldn't be read at all.
    private var fanRPMRange: (min: Int, max: Int)? {
        guard let fan = appState.latestStatus?.fans.first else { return nil }
        return (fan.minRPM, fan.maxRPM)
    }

    /// A curve point's fan value in whichever unit `useRPM` selects. Storage is
    /// always `fanPercent`; this is a converting view onto it, clamped in RPM terms
    /// first so it can never store outside 0...100% even via the RPM field.
    private func fanValueBinding(_ index: Int) -> Binding<Double> {
        guard useRPM, let range = fanRPMRange else {
            return clampedToPercentRange($points[index].fanPercent)
        }
        let maxRPM = Double(range.max)
        guard maxRPM > 0 else { return clampedToPercentRange($points[index].fanPercent) }
        return Binding(
            get: { (points[index].fanPercent / 100) * maxRPM },
            set: { rpm in
                let clampedRPM = min(max(rpm, 0), maxRPM)
                points[index].fanPercent = (clampedRPM / maxRPM) * 100
            }
        )
    }

    /// Placeholder swatch color while a point has no color set — a light neutral
    /// tint, visually distinct from any real (more saturated) color choice.
    private static let noColorSwatch = Color.gray.opacity(0.25)

    /// A curve point's color as a non-optional `Color` for `ColorPicker`, which has
    /// no "unset" state of its own. Reads back `noColorSwatch` when nil; picking any
    /// color sets it (the "x" button next to the swatch is what clears it back out).
    private func colorBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: { points[index].color ?? Self.noColorSwatch },
            set: { points[index].color = $0 }
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
            let curvePoints = points.map { point in
                FanCurvePoint2D(
                    sensorAValue: Float(point.sensorAValue), sensorBValue: Float(point.sensorBValue), fanPercent: Float(point.fanPercent),
                    color: point.color.flatMap(\.pointColor)
                )
            }
            let customCurve2D = try CustomCurve2D(sensorA: sensorA, sensorB: sensorB, points: curvePoints)

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
