import AppKit
import SwiftUI
import Testing
@testable import ThermalForgeApp
@testable import ThermalForgeCore
import ThermalForgeLocalization

@Suite("Localized panels — offscreen, no services", .serialized)
@MainActor
struct LocalizedPanelTests {
    @Test("One retained panel refreshes in three languages with all warning layouts")
    func panelLayouts() async throws {
        let name = "ThermalForge.PanelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let language = AppLanguageStore(defaults: defaults, preferredLanguages: { ["en"] })
        let state = AppState(startServices: false)
        state.activeProfile = .smart
        state.monitorState = .active(profileName: "Smart")
        state.latestStatus = ThermalStatus(fans: [
            .init(index: 0, actualRPM: 5777, targetRPM: 5777, minRPM: 1350, maxRPM: 5777, mode: "manual"),
            .init(index: 1, actualRPM: 5756, targetRPM: 5777, minRPM: 1350, maxRPM: 5777, mode: "manual"),
        ], temperatures: ["TCMb": 100, "Tg05": 73.7, "TRDX": 43.4, "TH0x": 26.3, "TAOL": 24.4])
        let identity = ObjectIdentifier(state)
        let panel = NSHostingView(rootView: MenuBarView().environmentObject(state).environmentObject(language)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        for scenario in ["normal", "held-update", "mismatch-safety", "daemon-down"] {
            state.externalHold = scenario == "held-update" ? DaemonHoldState(command: "setfan 1 5777", owner: "cli") : nil
            state.availableUpdate = scenario == "held-update" ? AvailableUpdate(version: "99.99.99", url: "https://github.com/ProducerGuy/ThermalForge/releases") : nil
            state.daemonVersionMismatch = scenario == "mismatch-safety" ? "0.2.2" : nil
            state.daemonUnreachable = scenario == "daemon-down"
            state.monitorState = scenario == "mismatch-safety" ? .safetyOverride : .active(profileName: "Smart")
            let hold = state.externalHold
            let monitor = state.monitorState
            for choice in LocalizationCatalog.supportedLanguages {
                language.select(choice)
                try await Task.sleep(for: .milliseconds(30))
                panel.setFrameSize(panel.fittingSize)
                panel.layoutSubtreeIfNeeded()
                #expect(panel.frame.width == 260)
                #expect(panel.frame.height > 300 && panel.frame.height < 1000)
                #expect(ObjectIdentifier(state) == identity)
                #expect(state.activeProfile == .smart)
                #expect(state.monitorState == monitor)
                #expect(state.externalHold == hold)
                let bitmap = try #require(panel.bitmapImageRepForCachingDisplay(in: panel.bounds))
                panel.cacheDisplay(in: panel.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(png.count > 1000)
                if let directory = ProcessInfo.processInfo.environment["THERMALFORGE_PREVIEW_DIR"] {
                    let url = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    try png.write(to: url.appendingPathComponent("\(scenario)-\(choice.rawValue).png"))
                }
            }
        }
    }
}
