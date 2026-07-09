//
//  MenuBarView.swift
//  ThermalForge
//
//  Menu bar dropdown — redesigned with:
//  - Collapsible sections (CPU, GPU, Memory, Storage, Battery, Fans)
//  - Per-core CPU temperatures
//  - Temperature sparklines for CPU and GPU
//  - Fan RPM sparkline
//  - Package power draw (CPU + GPU watts)
//  - Battery health (charge, health%, cycle count, condition)
//  - Delta-T over ambient display
//  - Thermal pressure badge
//  - Named sensor labels via SensorLabels
//  - 340px wide panel
//

import SwiftUI
import ThermalForgeCore

// MARK: - Section collapse state keys

private extension String {
    static let collapseKeyPrefix = "tf.section.collapsed."
}

// MARK: - MenuBarView

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    @AppStorage("tf.simpleView")                private var simpleView      = false
    @AppStorage("tf.section.collapsed.cpu")     private var cpuCollapsed    = false
    @AppStorage("tf.section.collapsed.gpu")     private var gpuCollapsed    = false
    @AppStorage("tf.section.collapsed.memory")  private var memCollapsed    = true
    @AppStorage("tf.section.collapsed.storage") private var ssdCollapsed    = true
    @AppStorage("tf.section.collapsed.battery") private var battCollapsed   = false
    @AppStorage("tf.section.collapsed.fans")    private var fansCollapsed   = false

    var body: some View {
        if simpleView {
            SimpleMenuBarView(simpleView: $simpleView)
                .environmentObject(appState)
        } else {
            detailedView
        }
    }

    private var detailedView: some View {
        VStack(alignment: .leading, spacing: 0) {

            headerRow
            Divider()

            // MARK: CPU Section
            CollapsibleSection(title: "CPU", collapsed: $cpuCollapsed) {
                cpuSection
            }

            Divider().padding(.vertical, 2)

            // MARK: GPU Section
            CollapsibleSection(title: "GPU", collapsed: $gpuCollapsed) {
                gpuSection
            }

            Divider().padding(.vertical, 2)

            // MARK: Memory Section
            CollapsibleSection(title: "MEMORY", collapsed: $memCollapsed) {
                memorySection
            }

            Divider().padding(.vertical, 2)

            // MARK: Storage Section
            CollapsibleSection(title: "STORAGE", collapsed: $ssdCollapsed) {
                storageSection
            }

            // MARK: Battery Section (only on laptops)
            if appState.hasBattery {
                Divider().padding(.vertical, 2)
                CollapsibleSection(title: "BATTERY", collapsed: $battCollapsed) {
                    batterySection
                }
            }

            Divider().padding(.vertical, 2)

            // MARK: Fans Section
            CollapsibleSection(title: "FANS", collapsed: $fansCollapsed) {
                fansSection
            }

            Divider().padding(.vertical, 4)

            // MARK: Profile Picker
            profileSection

            Divider().padding(.vertical, 4)

            // MARK: Quick Actions
            quickActions

            Divider().padding(.vertical, 4)

            // MARK: Footer
            footerSection
        }
        .frame(width: 340)
    }   // end detailedView

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("ThermalForge")
                    .font(.headline)
                thermalPressureBadge
            }
            Spacer()
            stateIndicator
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var thermalPressureBadge: some View {
        let pressure = appState.thermalPressure
        if pressure != .nominal {
            Label(pressureLabel(pressure), systemImage: pressureIcon(pressure))
                .font(.caption2)
                .foregroundStyle(pressureColor(pressure))
        }
    }

    private func pressureLabel(_ p: ThermalPressure) -> String {
        switch p {
        case .nominal:  return "Nominal"
        case .fair:     return "Warm"
        case .serious:  return "Throttling"
        case .critical: return "Critical Throttle"
        }
    }

    private func pressureIcon(_ p: ThermalPressure) -> String {
        switch p {
        case .nominal:  return "checkmark.circle"
        case .fair:     return "thermometer.medium"
        case .serious:  return "exclamationmark.triangle"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }

    private func pressureColor(_ p: ThermalPressure) -> Color {
        switch p {
        case .nominal:  return .secondary
        case .fair:     return .yellow
        case .serious:  return .orange
        case .critical: return .red
        }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch appState.monitorState {
        case .safetyOverride:
            Label("SAFETY", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        case .coolDown:
            Label("Cool-Down", systemImage: "thermometer.medium")
                .font(.caption).foregroundStyle(.orange)
        case .active(let name):
            Label(name, systemImage: "fan.fill")
                .font(.caption).foregroundStyle(.orange)
        case .idle:
            Label("Idle", systemImage: "fan")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - CPU Section

    @ViewBuilder
    private var cpuSection: some View {
        if let status = appState.latestStatus {
            // Peak CPU row with sparkline
            let peakCPU = peakTemp(status, prefixes: ["TC", "Tp"])
            HStack(spacing: 6) {
                Text("Peak")
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                TempSparkline(
                    buffer: appState.cpuSparkline,
                    fahrenheit: appState.useFahrenheit,
                    color: tempColor(peakCPU ?? 0)
                )
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)

            // Delta-T over ambient
            if let peak = peakCPU, let delta = appState.deltaT(for: peak) {
                DeltaRow(label: "dT Ambient", delta: delta, fahrenheit: appState.useFahrenheit)
            }
            // Power draw
            if let watts = status.power.cpuWatts {
                DataRow(label: "CPU Power") {
                    Text(String(format: "%.1f W", watts))
                        .font(.system(.body, design: .monospaced))
                }
            }

            // Per-core temperatures
            CPUCoresGrid(
                temperatures: status.temperatures,
                fahrenheit: appState.useFahrenheit
            )

            // Thermal throttle state
            let memPressure = status.memoryPressure
            if memPressure != .normal {
                DataRow(label: "Memory Pressure") {
                    Text(memPressure.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(memPressure == .critical ? .red : .orange)
                }
            }
        } else {
            placeholderRow("Reading sensors...")
        }
    }

    // MARK: - GPU Section

    @ViewBuilder
    private var gpuSection: some View {
        if let status = appState.latestStatus {
            let peakGPU = peakTemp(status, prefixes: ["TG", "Tg"])
            HStack(spacing: 6) {
                Text("Peak")
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                TempSparkline(
                    buffer: appState.gpuSparkline,
                    fahrenheit: appState.useFahrenheit,
                    color: tempColor(peakGPU ?? 0)
                )
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)

            // Individual GPU sensor rows — active cores first, then package sensors dimmed
            let gpuActive = status.temperatures
                .filter { k, v in (k.hasPrefix("Tg")) && v > 35 }
                .sorted { $0.key < $1.key }
            let gpuPackage = status.temperatures
                .filter { k, _ in k.hasPrefix("TG") }
                .sorted { $0.key < $1.key }

            ForEach(gpuActive, id: \.key) { key, value in
                SensorRow(label: SensorLabels.shared.name(for: key),
                          value: value, fahrenheit: appState.useFahrenheit)
            }
            ForEach(gpuPackage, id: \.key) { key, value in
                SensorRow(label: SensorLabels.shared.name(for: key),
                          value: value, fahrenheit: appState.useFahrenheit,
                          dimmed: true)
            }

            if let watts = status.power.gpuWatts {
                DataRow(label: "GPU Power") {
                    Text(String(format: "%.1f W", watts))
                        .font(.system(.body, design: .monospaced))
                }
            }

            if let pkg = status.power.packageWatts {
                DataRow(label: "Package Total") {
                    Text(String(format: "%.1f W", pkg))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // GPU utilization
            if let gpuPct = status.gpuPercent {
                UtilizationRow(label: "GPU Util", percent: gpuPct, color: .purple)
            }

            // Neural Engine utilization
            if let anePct = status.anePercent {
                UtilizationRow(label: "ANE Util", percent: anePct, color: .teal)
            }
        } else {
            placeholderRow("Reading sensors...")
        }
    }

    // MARK: - Memory Section

    @ViewBuilder
    private var memorySection: some View {
        if let status = appState.latestStatus {
            // Used / Total GB
            let used  = status.memoryUsedGB
            let total = status.memoryTotalGB
            if total > 0 {
                HStack {
                    Text("RAM Used")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f / %.0f GB", used, total))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(used / total > 0.9 ? .red : used / total > 0.75 ? .orange : .primary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 1)
            }

            // Memory pressure
            DataRow(label: "Pressure") {
                let mp = status.memoryPressure
                Text(mp.rawValue.capitalized)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(mp == .critical ? .red : mp == .warning ? .orange : .secondary)
            }

            // RAM temp sensors
            let ramSensors = status.temperatures
                .filter { k, _ in k.hasPrefix("Tm") || k == "TRDX" || k == "TMVR" }
                .sorted { $0.key < $1.key }
            ForEach(ramSensors, id: \.key) { key, value in
                SensorRow(label: SensorLabels.shared.name(for: key),
                          value: value, fahrenheit: appState.useFahrenheit)
            }
        } else {
            placeholderRow("Reading sensors...")
        }
    }

    // MARK: - Storage Section

    @ViewBuilder
    private var storageSection: some View {
        if let status = appState.latestStatus {
            let ssdSensors = status.temperatures
                .filter { k, _ in k.hasPrefix("TH") }
                .sorted { $0.key < $1.key }
            if ssdSensors.isEmpty {
                placeholderRow("No SSD sensors detected")
            } else {
                ForEach(ssdSensors, id: \.key) { key, value in
                    SensorRow(
                        label: SensorLabels.shared.name(for: key),
                        value: value,
                        fahrenheit: appState.useFahrenheit
                    )
                }
            }
        } else {
            placeholderRow("Reading sensors...")
        }
    }

    // MARK: - Battery Section

    @ViewBuilder
    private var batterySection: some View {
        if let bat = appState.batteryStatus, bat.isPresent {
            // Charge bar + percentage
            HStack {
                Text("Charge")
                    .foregroundStyle(.secondary)
                Spacer()
                BatteryChargeBar(percent: bat.chargePercent, isCharging: bat.isCharging)
                    .frame(width: 80, height: 12)
                Text("\(bat.chargePercent)%")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 36, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)

            // Health
            if let hp = bat.healthPercent {
                DataRow(label: "Health") {
                    HStack(spacing: 4) {
                        Text("\(hp)%")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(hp < 80 ? .orange : .primary)
                        if bat.condition != .normal && bat.condition != .unknown {
                            Text(bat.condition.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            // Cycle count
            if let cycles = bat.cycleCount {
                DataRow(label: "Cycles") {
                    Text("\(cycles)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(cycles > 1000 ? .red : cycles > 500 ? .orange : .primary)
                }
            }

            // Temperature
            if let tempC = bat.temperatureC {
                SensorRow(
                    label: "Temp",
                    value: tempC,
                    fahrenheit: appState.useFahrenheit
                )
            }

            // Time estimate
            if bat.isCharging, let ttf = bat.timeToFullMinutes {
                DataRow(label: "Time to Full") {
                    Text(formatMinutes(ttf))
                        .font(.system(.body, design: .monospaced))
                }
            } else if !bat.isCharging, let tr = bat.timeRemainingMinutes {
                DataRow(label: "Time Left") {
                    Text(formatMinutes(tr))
                        .font(.system(.body, design: .monospaced))
                }
            }

            // Voltage / Amperage
            if let mv = bat.voltageMV {
                DataRow(label: "Voltage") {
                    Text(String(format: "%.2f V", Float(mv) / 1000))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            placeholderRow("No battery")
        }
    }

    // MARK: - Fans Section

    @ViewBuilder
    private var fansSection: some View {
        if let status = appState.latestStatus {
            ForEach(status.fans, id: \.index) { fan in
                VStack(spacing: 2) {
                    HStack {
                        Text("Fan \(fan.index)")
                            .foregroundStyle(.secondary)
                        Text("(\(fan.mode))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("\(fan.actualRPM) RPM")
                            .font(.system(.body, design: .monospaced))
                    }
                    .padding(.horizontal, 12)

                    if fan.index == 0 {
                        SparklineView(
                            buffer: appState.fan0Sparkline,
                            color: .blue,
                            valueRange: 0...Float(fan.maxRPM > 0 ? fan.maxRPM : 8000),
                            unit: "RPM",
                            showLabel: false
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 1)
            }

            if let fan0 = status.fans.first {
                HStack {
                    Text("Range")
                        .foregroundStyle(.tertiary)
                        .font(.caption2)
                    Spacer()
                    Text("\(fan0.minRPM)–\(fan0.maxRPM) RPM")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 1)
            }

            // Manual override slider
            FanOverrideSlider()
        } else {
            placeholderRow("Reading fans...")
        }
    }

    // MARK: - Profile Section

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "PROFILE")
            Picker("Profile", selection: Binding(
                get: { appState.activeProfile.id },
                set: { id in
                    if let profile = FanProfile.builtIn.first(where: { $0.id == id }) {
                        appState.selectProfile(profile)
                    }
                }
            )) {
                ForEach(FanProfile.builtIn) { profile in
                    HStack {
                        Text(profile.name)
                        Spacer()
                        if !profile.curve.handsOff {
                            let unit = appState.useFahrenheit ? "F" : "C"
                            if profile.curve.instantEngage {
                                let startC = profile.curve.startTemp
                                let startDisp = appState.useFahrenheit ? startC * 9 / 5 + 32 : startC
                                Text("\(Int(startDisp))°\(unit) instant")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                let startC = profile.curve.startTemp
                                let ceilC  = profile.curve.ceilingTemp
                                let sd = appState.useFahrenheit ? startC * 9 / 5 + 32 : startC
                                let cd = appState.useFahrenheit ? ceilC  * 9 / 5 + 32 : ceilC
                                Text("\(Int(sd))→\(Int(cd))°\(unit)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tag(profile.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .padding(.horizontal, 12)
        }
    }

    // MARK: - Quick Actions

    private var quickActions: some View {
        HStack(spacing: 8) {
            Button(action: { appState.setSmart() }) {
                Label("Smart", systemImage: "fan.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.orange)

            Button(action: { appState.resetAuto() }) {
                Label("Default", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button(action: openProfileEditor) {
                Label("Custom", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 0) {
            Toggle("Fahrenheit", isOn: $appState.useFahrenheit)
                .padding(.horizontal, 12)
            Toggle("Cycle Menu Bar", isOn: $appState.menuBarCyclingEnabled)
                .padding(.horizontal, 12)
            Toggle("Simple View", isOn: $simpleView)
                .padding(.horizontal, 12)
            Toggle("Launch at Login", isOn: $appState.launchAtLogin)
                .padding(.horizontal, 12)

            Button(action: { NSApp.terminate(nil) }) {
                Text("Quit ThermalForge")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Helpers

    private func peakTemp(_ status: ThermalStatus, prefixes: [String]) -> Float? {
        let vals = status.temperatures
            .filter { k, _ in prefixes.contains(where: { k.hasPrefix($0) }) }
            .values
        return vals.max()
    }

    private func tempColor(_ temp: Float) -> Color {
        if temp >= 90 { return .red }
        if temp >= 75 { return .orange }
        if temp >= 60 { return .yellow }
        return .primary
    }

    @ViewBuilder
    private func tempLabel(_ tempC: Float, size: Font.TextStyle = .body) -> some View {
        let display = appState.useFahrenheit ? tempC * 9 / 5 + 32 : tempC
        let unit    = appState.useFahrenheit ? "F" : "C"
        Text(String(format: "%.1f°\(unit)", display))
            .font(.system(size, design: .monospaced))
            .foregroundStyle(tempColor(tempC))
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private func openProfileEditor() {
        // Open profile editor in a separate window
        let controller = NSWindowController(
            window: NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
        )
        controller.window?.title = "Custom Profile"
        controller.window?.contentView = NSHostingView(
            rootView: ProfileEditorView()
                .environmentObject(appState)
        )
        controller.window?.center()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @ViewBuilder
    private func placeholderRow(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }
}

// MARK: - CollapsibleSection

private struct CollapsibleSection<Content: View>: View {
    let title: String
    @Binding var collapsed: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() } }) {
                HStack {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsed {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - SectionHeader

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 2)
    }
}

// MARK: - SensorRow

private struct SensorRow: View {
    let label: String
    let value: Float
    var fahrenheit: Bool = false
    var dimmed: Bool = false

    var body: some View {
        HStack {
            Text(label).foregroundStyle(dimmed ? Color.secondary.opacity(0.5) : Color.secondary)
            Spacer()
            let display = fahrenheit ? value * 9 / 5 + 32 : value
            let unit    = fahrenheit ? "F" : "C"
            Text(String(format: "%.1f°\(unit)", display))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(dimmed ? Color.secondary.opacity(0.5) : tempColor(value))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
    }

    private func tempColor(_ t: Float) -> Color {
        if t >= 90 { return .red }
        if t >= 75 { return .orange }
        if t >= 60 { return .yellow }
        return .primary
    }
}

// MARK: - DataRow (generic right-side content)

private struct DataRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
    }
}

// MARK: - DeltaRow

private struct DeltaRow: View {
    let label: String
    let delta: Float
    var fahrenheit: Bool = false

    var body: some View {
        let display = fahrenheit ? delta * 9 / 5 : delta
        let unit    = fahrenheit ? "°F" : "°C"
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "+%.1f\(unit) above ambient", display))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
    }
}

// MARK: - BatteryChargeBar

private struct BatteryChargeBar: View {
    let percent: Int
    let isCharging: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(barColor)
                    .frame(width: geo.size.width * CGFloat(percent) / 100)
            }
        }
    }

    private var barColor: Color {
        if isCharging { return .green }
        if percent <= 10 { return .red }
        if percent <= 20 { return .orange }
        return .green
    }
}

// MARK: - FanOverrideSlider

private struct FanOverrideSlider: View {
    @EnvironmentObject var appState: AppState
    @State private var sliderValue: Float = 0
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 4) {
            Divider().padding(.vertical, 2)

            HStack {
                Text(appState.fanOverrideRPM == nil ? "Manual Override" : "Override Active")
                    .font(.caption2)
                    .foregroundStyle(appState.fanOverrideRPM == nil ? Color.secondary : Color.orange)
                Spacer()
                if appState.fanOverrideRPM != nil {
                    Button("Release") {
                        appState.releaseFanOverride()
                        sliderValue = appState.fanMinRPM
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)

            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { sliderValue },
                        set: { newVal in
                            sliderValue = newVal
                            isDragging = true
                        }
                    ),
                    in: appState.fanMinRPM...appState.fanMaxRPM,
                    step: 100,
                    onEditingChanged: { editing in
                        if !editing && isDragging {
                            appState.setFanOverride(rpm: sliderValue)
                            isDragging = false
                        }
                    }
                )

                Text("\(Int(sliderValue))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(appState.fanOverrideRPM != nil ? .orange : .secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, 12)
        }
        .onAppear {
            sliderValue = appState.fanOverrideRPM ?? appState.fanMinRPM
        }
        .onChange(of: appState.fanOverrideRPM) { _, newVal in
            if newVal == nil { sliderValue = appState.fanMinRPM }
        }
    }
}

// MARK: - UtilizationRow

private struct UtilizationRow: View {
    let label: String
    let percent: Double
    var color: Color = .purple

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.7))
                        .frame(width: geo.size.width * CGFloat(min(percent, 100) / 100))
                }
            }
            .frame(height: 6)
            Text(String(format: "%.0f%%", min(percent, 100)))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(percent > 80 ? color : .secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }
}

// MARK: - CPUCoresGrid

private struct CPUCoresGrid: View {
    let temperatures: [String: Float]
    var fahrenheit: Bool = false

    private var cores: [(label: String, value: Float)] {
        SensorLabels.shared.cpuCores(from: temperatures)
    }

    var body: some View {
        if cores.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                ForEach(stride(from: 0, to: cores.count, by: 2).map { $0 }, id: \.self) { i in
                    HStack(spacing: 0) {
                        coreCell(cores[i])
                        if i + 1 < cores.count {
                            coreCell(cores[i + 1])
                        } else {
                            Spacer().frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    @ViewBuilder
    private func coreCell(_ core: (label: String, value: Float)) -> some View {
        HStack {
            Text(core.label)
                .foregroundStyle(.tertiary)
                .font(.caption)
            Spacer()
            let display = fahrenheit ? core.value * 9 / 5 + 32 : core.value
            let unit    = fahrenheit ? "F" : "C"
            Text(String(format: "%.0f°\(unit)", display))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(coreColor(core.value))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }

    private func coreColor(_ t: Float) -> Color {
        if t >= 90 { return .red }
        if t >= 75 { return .orange }
        if t >= 60 { return .yellow }
        return .primary
    }
}

// MARK: - SimpleMenuBarView

/// Lightweight view with no Canvas, no sparklines, no per-core grid.
/// Renders plain text rows only — minimal CPU/GPU usage for the menu bar redraw.
struct SimpleMenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Binding var simpleView: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Text("ThermalForge")
                    .font(.headline)
                Spacer()
                simpleStateIndicator
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            if let status = appState.latestStatus {
                // Temps — only aggregates, no per-core
                Group {
                    simpleRow("CPU",     peakTemp(status, prefixes: ["TC", "Tp"]))
                    simpleRow("GPU",     peakTemp(status, prefixes: ["TG", "Tg"]))
                    simpleRow("RAM",     peakTemp(status, prefixes: ["Tm", "TR", "TM"]))
                    simpleRow("SSD",     peakTemp(status, prefixes: ["TH"]))
                    simpleRow("Ambient", peakTemp(status, prefixes: ["TA"]))
                }

                Divider().padding(.vertical, 4)

                // Fans
                ForEach(status.fans, id: \.index) { fan in
                    HStack {
                        Text("Fan \(fan.index)")
                            .foregroundStyle(.secondary)
                        Text("(\(fan.mode))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("\(fan.actualRPM) RPM")
                            .font(.system(.body, design: .monospaced))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 1)
                }
            } else {
                Text("Reading sensors...")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }

            Divider().padding(.vertical, 4)

            // Profile picker (inline, same as detailed view)
            Picker("Profile", selection: Binding(
                get: { appState.activeProfile.id },
                set: { id in
                    if let p = FanProfile.builtIn.first(where: { $0.id == id }) {
                        appState.selectProfile(p)
                    }
                }
            )) {
                ForEach(FanProfile.builtIn) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .padding(.horizontal, 12)

            Divider().padding(.vertical, 4)

            // Quick actions
            HStack(spacing: 8) {
                Button(action: { appState.setSmart() }) {
                    Label("Smart", systemImage: "fan.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.orange)

                Button(action: { appState.resetAuto() }) {
                    Label("Default", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)

            Divider().padding(.vertical, 4)

            // Footer
            Toggle("Fahrenheit", isOn: $appState.useFahrenheit)
                .padding(.horizontal, 12)
            Toggle("Cycle Menu Bar", isOn: $appState.menuBarCyclingEnabled)
                .padding(.horizontal, 12)
            Toggle("Simple View", isOn: $simpleView)
                .padding(.horizontal, 12)
            Toggle("Launch at Login", isOn: $appState.launchAtLogin)
                .padding(.horizontal, 12)

            Button(action: { NSApp.terminate(nil) }) {
                Text("Quit ThermalForge")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
        .frame(width: 260)
    }

    // MARK: - Helpers

    @ViewBuilder
    private var simpleStateIndicator: some View {
        switch appState.monitorState {
        case .safetyOverride:
            Label("SAFETY", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        case .coolDown:
            Label("Cool-Down", systemImage: "thermometer.medium")
                .font(.caption).foregroundStyle(.orange)
        case .active(let name):
            Label(name, systemImage: "fan.fill")
                .font(.caption).foregroundStyle(.orange)
        case .idle:
            Label("Idle", systemImage: "fan")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func simpleRow(_ label: String, _ tempC: Float?) -> some View {
        if let t = tempC {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                let display = appState.useFahrenheit ? t * 9/5 + 32 : t
                let unit    = appState.useFahrenheit ? "F" : "C"
                Text(String(format: "%.1f°\(unit)", display))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(tempColor(t))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 1)
        }
    }

    private func peakTemp(_ status: ThermalStatus, prefixes: [String]) -> Float? {
        let vals = status.temperatures
            .filter { k, _ in prefixes.contains(where: { k.hasPrefix($0) }) }
            .values
        return vals.max()
    }

    private func tempColor(_ t: Float) -> Color {
        if t >= 90 { return .red }
        if t >= 75 { return .orange }
        if t >= 60 { return .yellow }
        return .primary
    }
}
