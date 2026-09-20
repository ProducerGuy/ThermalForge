import Combine
import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    public var id: String { rawValue }

    public static func resolve(preferredLanguages: [String]) -> AppLanguage {
        for identifier in preferredLanguages {
            let parts = identifier.replacingOccurrences(of: "_", with: "-")
                .lowercased().split(separator: "-").map(String.init)
            if parts.first == "en" { return .english }
            guard parts.first == "zh" else { continue }
            // An explicit script takes priority over region (e.g. zh-Hans-TW).
            if parts.contains("hans") { return .simplifiedChinese }
            if parts.contains("hant") { return .traditionalChinese }
            if parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) {
                return .traditionalChinese
            }
            return .simplifiedChinese
        }
        return .english
    }
}

/// Presentation state only. This module has no dependency on fan control,
/// profiles, the daemon or AppState; changing language cannot command hardware.
@MainActor
public final class AppLanguageStore: ObservableObject {
    public static let preferenceKey = "guiLanguage"
    @Published public private(set) var selection: AppLanguage
    @Published public private(set) var language: AppLanguage
    private let defaults: UserDefaults
    private let preferredLanguages: () -> [String]
    private let catalog: LocalizationCatalog
    private var localeObserver: AnyCancellable?

    public init(defaults: UserDefaults = .standard,
                preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages },
                catalog: LocalizationCatalog = .bundled) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        self.catalog = catalog
        let selected = defaults.string(forKey: Self.preferenceKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
        selection = selected
        language = selected == .system ? AppLanguage.resolve(preferredLanguages: preferredLanguages()) : selected
        localeObserver = NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSystemLanguage() }
            }
    }

    public func select(_ choice: AppLanguage) {
        guard selection != choice else { return }
        defaults.set(choice.rawValue, forKey: Self.preferenceKey)
        selection = choice
        refreshSystemLanguage()
    }

    public func refreshSystemLanguage() {
        let resolved = selection == .system
            ? AppLanguage.resolve(preferredLanguages: preferredLanguages()) : selection
        if language != resolved { language = resolved }
    }

    public func text(_ english: String, _ arguments: [String: String] = [:]) -> String {
        catalog.text(english, language: language, arguments: arguments)
    }

    public func title(for choice: AppLanguage) -> String {
        switch choice {
        case .system: return text("Follow System")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        }
    }
}
