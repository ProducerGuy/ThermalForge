//
//  ProfileEditorView.swift
//  ThermalForge
//
//  Custom fan profile editor.
//  Users can create, edit, save, and delete custom profiles.
//  All custom profiles persist to ~/Library/Application Support/ThermalForge/profiles/
//
//  Constraints enforced in real-time:
//  - stopTemp must be ≥ 5°C below startTemp (hysteresis)
//  - startTemp must be < ceilingTemp
//  - maxRPMPercent clamped to 10%–100%
//

import SwiftUI
import ThermalForgeCore

// MARK: - EditableProfile (working copy separate from immutable FanProfile)

private struct EditableProfile: Identifiable {
    var id: String
    var name: String
    var stopTemp: Float
    var startTemp: Float
    var ceilingTemp: Float
    var maxRPMPercent: Float  // 0.0–1.0
    var curveShape: CurveShape
    var rampUpPerSec: Float
    var rampDownPerSec: Float
    var sustainedTriggerSec: Float

    static let defaults = EditableProfile(
        id: UUID().uuidString,
        name: "My Profile",
        stopTemp: 50,
        startTemp: 58,
        ceilingTemp: 72,
        maxRPMPercent: 0.70,
        curveShape: .sCurve,
        rampUpPerSec: 0.07,
        rampDownPerSec: 0.03,
        sustainedTriggerSec: 6
    )

    init(id: String, name: String, stopTemp: Float, startTemp: Float, ceilingTemp: Float,
         maxRPMPercent: Float, curveShape: CurveShape, rampUpPerSec: Float,
         rampDownPerSec: Float, sustainedTriggerSec: Float) {
        self.id = id; self.name = name; self.stopTemp = stopTemp
        self.startTemp = startTemp; self.ceilingTemp = ceilingTemp
        self.maxRPMPercent = maxRPMPercent; self.curveShape = curveShape
        self.rampUpPerSec = rampUpPerSec; self.rampDownPerSec = rampDownPerSec
        self.sustainedTriggerSec = sustainedTriggerSec
    }

    init(from profile: FanProfile) {
        self.id = profile.id
        self.name = profile.name
        self.stopTemp = profile.curve.stopTemp
        self.startTemp = profile.curve.startTemp
        self.ceilingTemp = profile.curve.ceilingTemp
        self.maxRPMPercent = profile.curve.maxRPMPercent
        self.curveShape = profile.curve.curveShape
        self.rampUpPerSec = profile.curve.rampUpPerSec
        self.rampDownPerSec = profile.curve.rampDownPerSec
        self.sustainedTriggerSec = profile.curve.sustainedTriggerSec
    }

    func toFanProfile() -> FanProfile {
        FanProfile(
            id: id,
            name: name,
            curve: FanProfile.Curve(
                stopTemp: stopTemp,
                startTemp: startTemp,
                ceilingTemp: ceilingTemp,
                maxRPMPercent: maxRPMPercent,
                handsOff: false,
                alwaysOn: false,
                curveShape: curveShape,
                rampUpPerSec: rampUpPerSec,
                rampDownPerSec: rampDownPerSec,
                sustainedTriggerSec: sustainedTriggerSec,
                instantEngage: false
            )
        )
    }

    var validationErrors: [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Profile name cannot be empty.")
        }
        if startTemp - stopTemp < 5 {
            errors.append("Start temp must be ≥ 5°C above stop temp (hysteresis requirement).")
        }
        if ceilingTemp <= startTemp {
            errors.append("Ceiling temp must be above start temp.")
        }
        if maxRPMPercent < 0.1 || maxRPMPercent > 1.0 {
            errors.append("Max fan speed must be between 10% and 100%.")
        }
        return errors
    }

    var isValid: Bool { validationErrors.isEmpty }
}

// MARK: - ProfileEditorView

struct ProfileEditorView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var customProfiles: [EditableProfile] = []
    @State private var selectedIndex: Int? = nil
    @State private var editing: EditableProfile = .defaults
    @State private var saveError: String? = nil
    @State private var showDeleteConfirm = false
    @State private var profileToDelete: String? = nil

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar: list of custom profiles
            profileList
                .frame(width: 140)
                .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Editor: form for selected profile
            editorForm
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 480)
        .onAppear { loadProfiles() }
        .alert("Delete Profile?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: - Profile List

    private var profileList: some View {
        VStack(spacing: 0) {
            Text("CUSTOM PROFILES")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)

            if customProfiles.isEmpty {
                Text("No custom profiles yet.\nTap + to create one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(10)
            } else {
                List(Array(customProfiles.enumerated()), id: \.element.id,
                     selection: $selectedIndex) { idx, profile in
                    Text(profile.name)
                        .font(.body)
                        .tag(idx)
                        .lineLimit(1)
                }
                .listStyle(.sidebar)
                .onChange(of: selectedIndex) { _, newIdx in
                    if let i = newIdx {
                        editing = customProfiles[i]
                        saveError = nil
                    }
                }
            }

            Spacer()

            HStack {
                // New profile
                Button(action: newProfile) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("New custom profile")

                Spacer()

                // Delete selected
                Button(action: {
                    if let i = selectedIndex {
                        profileToDelete = customProfiles[i].id
                        showDeleteConfirm = true
                    }
                }) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.plain)
                .disabled(selectedIndex == nil)
                .help("Delete selected profile")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Editor Form

    @ViewBuilder
    private var editorForm: some View {
        if customProfiles.isEmpty && selectedIndex == nil {
            VStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Create a custom profile to define your own fan curve.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Button("New Profile", action: newProfile)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // Name
                    FormSection(label: "Name") {
                        TextField("Profile name", text: $editing.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Temperature Range
                    FormSection(label: "Temperature Range") {
                        VStack(spacing: 10) {
                            TempSlider(
                                label: "Fans Off (stop)",
                                value: $editing.stopTemp,
                                range: 35...70,
                                description: "Below this, fans turn off."
                            ) { newVal in
                                // Keep hysteresis: startTemp ≥ stopTemp + 5
                                if editing.startTemp < newVal + 5 {
                                    editing.startTemp = newVal + 5
                                }
                                if editing.ceilingTemp <= editing.startTemp {
                                    editing.ceilingTemp = editing.startTemp + 5
                                }
                            }
                            TempSlider(
                                label: "Fans On (start)",
                                value: $editing.startTemp,
                                range: 40...90,
                                description: "Fans engage after sustained trigger."
                            ) { newVal in
                                if newVal < editing.stopTemp + 5 {
                                    editing.stopTemp = newVal - 5
                                }
                                if editing.ceilingTemp <= newVal {
                                    editing.ceilingTemp = newVal + 5
                                }
                            }
                            TempSlider(
                                label: "Max Speed (ceiling)",
                                value: $editing.ceilingTemp,
                                range: 50...100,
                                description: "Fan reaches max speed at this temp."
                            ) { newVal in
                                if newVal <= editing.startTemp {
                                    editing.startTemp = newVal - 5
                                }
                            }
                        }
                    }

                    // Max RPM
                    FormSection(label: "Max Fan Speed") {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Slider(value: $editing.maxRPMPercent, in: 0.10...1.0, step: 0.05)
                                Text("\(Int(editing.maxRPMPercent * 100))%")
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 40, alignment: .trailing)
                            }
                            Text("Maximum fan speed as % of hardware max RPM.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Curve Shape
                    FormSection(label: "Curve Shape") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Curve", selection: $editing.curveShape) {
                                Text("S-Curve (smooth)").tag(CurveShape.sCurve)
                                Text("Ease-In (quiet start)").tag(CurveShape.easeIn)
                                Text("Linear (proportional)").tag(CurveShape.linear)
                                Text("Ease-Out (fast start)").tag(CurveShape.easeOut)
                            }
                            .pickerStyle(.segmented)
                            Text(curveDescription(editing.curveShape))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Trigger & Ramp
                    FormSection(label: "Responsiveness") {
                        VStack(spacing: 10) {
                            LabeledSlider(
                                label: "Sustained Trigger",
                                value: $editing.sustainedTriggerSec,
                                range: 1...20, step: 1,
                                format: "%.0f sec",
                                description: "Seconds at start temp before fans engage. Filters transient spikes."
                            )
                            LabeledSlider(
                                label: "Ramp Up Speed",
                                value: $editing.rampUpPerSec,
                                range: 0.02...0.3, step: 0.01,
                                format: "%.2f/s",
                                description: "Fan speed increase per second (fraction of max RPM)."
                            )
                            LabeledSlider(
                                label: "Ramp Down Speed",
                                value: $editing.rampDownPerSec,
                                range: 0.01...0.15, step: 0.005,
                                format: "%.3f/s",
                                description: "Fan speed decrease per second. Slower = quieter transitions."
                            )
                        }
                    }

                    // Curve preview
                    FormSection(label: "Preview") {
                        CurvePreviewView(profile: editing)
                            .frame(height: 80)
                    }

                    // Validation errors
                    if let err = saveError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 4)
                    }

                    // Save / Activate buttons
                    HStack {
                        Button("Save Profile") {
                            _ = saveProfile()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!editing.isValid)

                        Button("Save & Activate") {
                            let saved = saveProfile()
                            if saved {
                                appState.selectProfile(editing.toFanProfile())
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!editing.isValid)
                    }
                    .padding(.bottom, 16)
                }
                .padding(16)
            }
        }
    }

    // MARK: - Actions

    private func newProfile() {
        var fresh = EditableProfile.defaults
        fresh.id = UUID().uuidString
        fresh.name = "My Profile \(customProfiles.count + 1)"
        customProfiles.append(fresh)
        selectedIndex = customProfiles.count - 1
        editing = fresh
        saveError = nil
    }

    @discardableResult
    private func saveProfile() -> Bool {
        let errors = editing.validationErrors
        guard errors.isEmpty else {
            saveError = errors.joined(separator: "\n")
            return false
        }
        saveError = nil

        let profile = editing.toFanProfile()
        do {
            try profile.save()
        } catch {
            saveError = "Save failed: \(error.localizedDescription)"
            return false
        }

        // Update in-memory list
        if let i = selectedIndex, i < customProfiles.count {
            customProfiles[i] = editing
        }
        TFLogger.shared.profile("Custom profile saved: \(editing.name)")
        return true
    }

    private func confirmDelete() {
        guard let id = profileToDelete else { return }
        guard let i = customProfiles.firstIndex(where: { $0.id == id }) else { return }

        // Remove saved file
        let fileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThermalForge/profiles/\(id).json")
        try? FileManager.default.removeItem(at: fileURL)

        customProfiles.remove(at: i)
        if customProfiles.isEmpty {
            selectedIndex = nil
        } else {
            selectedIndex = max(0, i - 1)
            editing = customProfiles[selectedIndex!]
        }
        TFLogger.shared.profile("Custom profile deleted: \(id)")
    }

    private func loadProfiles() {
        // Load all profiles, filter to non-built-in ones
        let builtInIDs = Set(FanProfile.builtIn.map { $0.id })
        let all = FanProfile.loadAll()
        customProfiles = all
            .filter { !builtInIDs.contains($0.id) }
            .map { EditableProfile(from: $0) }
        if !customProfiles.isEmpty {
            selectedIndex = 0
            editing = customProfiles[0]
        }
    }

    // MARK: - Helpers

    private func curveDescription(_ shape: CurveShape) -> String {
        switch shape {
        case .sCurve:  return "Smooth at both ends — gentle start, gentle finish. Best for everyday use."
        case .easeIn:  return "Quiet at low temps, accelerates as heat builds. Prioritizes silence."
        case .linear:  return "Direct proportional response. Fan tracks temperature exactly."
        case .easeOut: return "Fast initial response, then levels off. Good for heavy workloads."
        }
    }
}

// MARK: - CurvePreviewView

/// Canvas that draws the fan curve for the currently edited profile.
private struct CurvePreviewView: View {
    let profile: EditableProfile

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let minTemp: Float = 40
            let maxTemp: Float = 100
            let tempRange = maxTemp - minTemp

            func x(_ temp: Float) -> CGFloat {
                CGFloat((temp - minTemp) / tempRange) * w
            }
            func y(_ pct: Float) -> CGFloat {
                h - CGFloat(pct) * h
            }

            // Background grid lines at 25% intervals
            for pct: Float in [0.25, 0.5, 0.75] {
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: y(pct)))
                grid.addLine(to: CGPoint(x: w, y: y(pct)))
                ctx.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
            }

            // Build curve path
            var path = Path()
            var first = true
            let steps = 200
            for i in 0...steps {
                let temp = minTemp + Float(i) / Float(steps) * tempRange
                let curve = FanProfile.Curve(
                    stopTemp: profile.stopTemp,
                    startTemp: profile.startTemp,
                    ceilingTemp: profile.ceilingTemp,
                    maxRPMPercent: profile.maxRPMPercent,
                    curveShape: profile.curveShape
                )
                let pct = curve.targetPercent(at: temp, fansCurrentlyRunning: true) ?? 0

                let pt = CGPoint(x: x(temp), y: y(pct))
                if first { path.move(to: pt); first = false }
                else      { path.addLine(to: pt) }
            }

            // Fill under curve
            var fill = path
            fill.addLine(to: CGPoint(x: w, y: h))
            fill.addLine(to: CGPoint(x: 0, y: h))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [Color.orange.opacity(0.3), Color.orange.opacity(0.05)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: h)
            ))

            // Stroke curve
            ctx.stroke(path, with: .color(.orange), lineWidth: 2)

            // Stop/Start/Ceiling markers
            for (temp, label) in [(profile.stopTemp, "off"), (profile.startTemp, "on"), (profile.ceilingTemp, "max")] {
                var marker = Path()
                marker.move(to: CGPoint(x: x(temp), y: 0))
                marker.addLine(to: CGPoint(x: x(temp), y: h))
                ctx.stroke(marker, with: .color(.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                ctx.draw(
                    Text(label).font(.system(size: 8)).foregroundStyle(Color.secondary),
                    at: CGPoint(x: x(temp), y: 6)
                )
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }
}

// MARK: - FormSection

private struct FormSection<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - TempSlider

private struct TempSlider: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let description: String
    var onChange: ((Float) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value))°C")
                    .font(.system(.caption, design: .monospaced))
            }
            Slider(value: Binding(
                get: { value },
                set: { newVal in
                    value = newVal
                    onChange?(newVal)
                }
            ), in: range, step: 1)
            Text(description)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - LabeledSlider

private struct LabeledSlider: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let step: Float
    let format: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: format, value))
                    .font(.system(.caption, design: .monospaced))
            }
            Slider(value: $value, in: range, step: step)
            Text(description)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
