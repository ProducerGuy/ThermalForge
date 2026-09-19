//
//  ThermalForgeApp.swift
//  ThermalForge
//
//  Menu bar app for fan control on Apple Silicon MacBooks.
//

import AppKit
import Combine
import SwiftUI
import ThermalForgeCore

@main
struct ThermalForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Custom Profile editor — a real window (not the menu bar popover) since
        // it's a form, not a quick action. Opened via `openWindow(id: "profile-editor")`
        // after setting `appState.profileEditorTarget`. The menu bar item itself is
        // owned by `AppDelegate` via raw AppKit, not a `MenuBarExtra` scene — see its
        // doc comment for why — but `openWindow` still resolves this scene
        // registration app-wide no matter which view calls it.
        //
        // With no `MenuBarExtra` scene anymore, this `Window` is the app's ONLY
        // scene — and SwiftUI auto-presents an app's sole scene at launch unless
        // told otherwise. `.defaultLaunchBehavior(.suppressed)` (the real fix)
        // needs macOS 15, but this project supports macOS 14+, and `SceneBuilder`
        // has no `buildLimitedAvailability` to branch on `#available` here — so the
        // auto-opened window is closed imperatively instead, in
        // `AppDelegate.applicationDidFinishLaunching`. (The other half of that bug
        // — quitting the whole app when this window closed — is
        // `applicationShouldTerminateAfterLastWindowClosed` in `AppDelegate`.)
        Window("Custom Profile", id: "profile-editor") {
            ProfileEditorWindow()
                .environmentObject(delegate.appState)
        }
        .windowResizability(.contentSize)
    }
}

/// Owns the menu bar status item directly via AppKit instead of SwiftUI's
/// `MenuBarExtra`. `MenuBarExtra` always composites its `label` view into a single
/// template-rendered (forced monochrome) glyph — confirmed by hardcoding the
/// per-point-color feature's color to a solid `.red` and observing the status item
/// still rendered in the default monochrome regardless. No `.foregroundStyle` /
/// `.renderingMode` combination inside a `MenuBarExtra` label can override that,
/// since the templating is applied by AppKit after SwiftUI hands over the
/// composited image — it isn't a SwiftUI-level bug to fix. A raw `NSStatusItem`
/// button's `image`/`attributedTitle` are NOT subject to that: setting
/// `image.isTemplate = false` renders genuine color, which is the whole reason
/// for this class instead of a `MenuBarExtra` scene.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var appStateSubscription: AnyCancellable?
    private var lastRenderKey: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)

        // Prevent duplicate instances
        let bundleID = Bundle.main.bundleIdentifier ?? "com.thermalforge.app"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            TFLogger.shared.error("Another instance already running — quitting")
            NSApp.terminate(nil)
        }

        setUpStatusItem()
        setUpPopover()
        observeAppState()
        updateStatusItem()

        // The "Custom Profile" editor is the app's only `Scene`, and SwiftUI
        // auto-presents an app's sole scene at launch — it should only ever appear
        // via `openWindow(id:)` (from the "New"/"Edit" buttons). Whatever SwiftUI
        // auto-opened hasn't been given a `profileEditorTarget` to edit, so it'd
        // show a blank/stale form anyway. Deferred one runloop turn because
        // SwiftUI's own window presentation for this launch hasn't necessarily
        // happened yet when this delegate method runs.
        //
        // ONLY the editor window: `NSApp.windows` also contains the private
        // `NSStatusBarWindow` hosting the status item's button — closing that one
        // leaves the icon drawn but dead to clicks.
        DispatchQueue.main.async {
            for window in NSApp.windows
            where window.identifier?.rawValue.contains("profile-editor") == true || window.title == "Custom Profile" {
                window.close()
            }
        }
    }

    /// This is a menu bar accessory app — it lives in the status item, not in any
    /// window, so closing the Custom Profile editor (or any other window) must
    /// never quit it. AppKit's default for a window-owning app is to quit when the
    /// last window closes; without this override, closing the editor took the
    /// whole app down with it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Reset fans on quit so the daemon doesn't hold stale APP settings — but
        // ONLY if the app owns the hold. A CLI hold (`sudo thermalforge max`) is the
        // user's deliberate, unsupervised choice; quitting the menu bar app must not
        // destroy it — that's the v0.1.7 arbitration feature. Synchronous on purpose:
        // the process is exiting, so an async write would be dropped; both calls are
        // bounded by the sendRaw timeout.
        let client = DaemonClient()
        if let state = try? client.readState(), state.owner == "app" {
            _ = try? client.execute(.resetAuto)
        }
        // owner == "cli" → leave the CLI hold alone; owner == "none" → nothing to reset.
    }

    // MARK: - Status item + popover

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
    }

    private func setUpPopover() {
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView().environmentObject(appState)
        )
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Accessory apps (LSUIElement — no Dock icon) don't automatically become
            // frontmost on click; without this the popover (and any window it opens,
            // e.g. the profile editor) can appear behind the previously-frontmost app.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Live updates

    /// The monitor publishes ~10x/sec (and each tick mutates several `@Published`
    /// properties); redrawing the status image that often wastes CPU for no visible
    /// gain, so redraws are throttled to once per second.
    ///
    /// `objectWillChange` fires BEFORE the triggering `@Published` mutation actually
    /// lands, so reading `appState` synchronously from the sink would see the stale
    /// value — hop one runloop turn so the read sees the settled state.
    private func observeAppState() {
        appStateSubscription = appState.objectWillChange
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        let iconName: String
        switch appState.monitorState {
        case .safetyOverride: iconName = "exclamationmark.triangle.fill"
        case .active: iconName = "fan.fill"
        case .idle: iconName = "fan"
        }

        var primaryText: String?
        var secondaryText: String?
        if let tempC = appState.maxTemp {
            let display = appState.useFahrenheit ? tempC * 9 / 5 + 32 : tempC
            primaryText = "\(Int(display))°"
            if appState.showRPMInMenuBar, let actualRPM = appState.latestStatus?.fans.first?.actualRPM {
                secondaryText = "\(actualRPM)"
            }
        }

        // `button.title`/`attributedTitle` are left untouched (always empty) — see
        // this method's doc comment for why.
        let renderKey = "\(iconName)|\(appState.colorizeMenuBarIcon ? "\(String(describing: appState.fanSpeedColor))" : "-")|\(appState.daemonVersionMismatch != nil)|\(primaryText ?? "")|\(secondaryText ?? "")"
        guard renderKey != lastRenderKey else { return }
        lastRenderKey = renderKey

        button.image = Self.statusImage(
            iconName: iconName,
            color: appState.colorizeMenuBarIcon ? appState.fanSpeedColor.map(NSColor.init) : nil,
            badge: appState.daemonVersionMismatch != nil,
            primaryText: primaryText,
            secondaryText: secondaryText
        )
        button.imagePosition = .imageOnly
    }

    /// Builds the ENTIRE status item glyph — icon plus temperature (and, with
    /// `showRPMInMenuBar` on, a second RPM line below it) — as one composited
    /// `NSImage`, rather than an icon `image` plus a separate `attributedTitle`.
    ///
    /// A multi-line `attributedTitle` is what briefly broke clicking the status
    /// item entirely (no highlight, no action — see git history around the RPM
    /// display feature): `NSStatusBarButton` is built for a single-line title, and
    /// handing it a two-line one corrupts the button's own width/height bookkeeping
    /// enough to throw off its hit-testing frame. Compositing everything into a
    /// single image sidesteps that: the button's clickable frame is derived
    /// directly from `image.size`, which this method controls precisely, so hit
    /// area and drawn content always agree — however many text lines there are.
    ///
    /// Text is always `NSColor.labelColor` (adapts to light/dark menu bar on its
    /// own) — per-point color is an icon-only signal, never applied to text. The
    /// icon itself is tinted with `color` when non-nil via the classic "draw the
    /// glyph, then sourceAtop-fill" AppKit trick (the templating `MenuBarExtra`
    /// can't be told to skip — see `AppDelegate`'s doc comment); with `color` nil it
    /// falls back to `labelColor` too, so the default (no colored point) look is
    /// unchanged from every profile's icon before the per-point-color feature
    /// existed.
    private static func statusImage(
        iconName: String, color: NSColor?, badge: Bool, primaryText: String?, secondaryText: String?
    ) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let iconSize = symbol.size
        let spacing: CGFloat = 3
        let iconColor = color ?? .labelColor

        var lines: [NSAttributedString] = []
        if let primaryText {
            let font = NSFont.monospacedDigitSystemFont(
                ofSize: secondaryText == nil ? NSFont.smallSystemFontSize : 9, weight: .regular
            )
            lines.append(NSAttributedString(string: primaryText, attributes: [
                .foregroundColor: NSColor.labelColor, .font: font
            ]))
        }
        if let secondaryText {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            lines.append(NSAttributedString(string: secondaryText, attributes: [
                .foregroundColor: NSColor.labelColor, .font: font
            ]))
        }

        let lineSizes = lines.map { $0.size() }
        let textWidth = lineSizes.map(\.width).max() ?? 0
        let textHeight = lineSizes.reduce(0) { $0 + $1.height }
        let textLeading = lines.isEmpty ? 0 : spacing + textWidth

        let canvasSize = NSSize(
            width: ceil(iconSize.width + textLeading) + 2,
            height: ceil(max(iconSize.height, textHeight))
        )

        let image = NSImage(size: canvasSize, flipped: false) { _ in
            let iconRect = NSRect(
                x: 0, y: (canvasSize.height - iconSize.height) / 2,
                width: iconSize.width, height: iconSize.height
            )
            symbol.draw(in: iconRect)
            iconColor.set()
            iconRect.fill(using: .sourceAtop)

            if badge {
                let dotSize: CGFloat = 5
                let dotRect = NSRect(
                    x: iconRect.maxX - dotSize, y: iconRect.maxY - dotSize, width: dotSize, height: dotSize
                )
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }

            var y = (canvasSize.height + textHeight) / 2
            for (line, size) in zip(lines, lineSizes) {
                y -= size.height
                line.draw(at: NSPoint(x: iconRect.maxX + spacing, y: y))
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
