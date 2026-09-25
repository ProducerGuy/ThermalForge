import Foundation

/// English text is the lookup key and ultimate fallback. New upstream copy
/// therefore stays readable even before translations have been added.
public struct LocalizationCatalog {
    public static let resourceBundleName = "ThermalForge_ThermalForgeLocalization.bundle"
    public static let supportedLanguages: [AppLanguage] = [.english, .simplifiedChinese, .traditionalChinese]
    private static let tokenPattern = try! NSRegularExpression(pattern: "\\{([A-Za-z][A-Za-z0-9_]*)\\}")
    public let translations: [AppLanguage: [String: String]]

    public init(translations: [AppLanguage: [String: String]]) {
        self.translations = translations
    }

    public init(bundle: Bundle) throws {
        var loaded: [AppLanguage: [String: String]] = [:]
        for language in Self.supportedLanguages {
            guard let url = bundle.url(forResource: language.rawValue, withExtension: "json") else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            loaded[language] = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        }
        self.init(translations: loaded)
    }

    public static let bundled: LocalizationCatalog = {
        // SwiftPM's generated Bundle.module accessor can contain a build-machine
        // fallback. Prefer the app's actual Resources directory after packaging.
        if Bundle.main.bundleURL.pathExtension == "app" {
            if let url = Bundle.main.resourceURL?.appendingPathComponent(resourceBundleName),
               let bundle = Bundle(url: url), let catalog = try? LocalizationCatalog(bundle: bundle) {
                return catalog
            }
            return LocalizationCatalog(translations: [:])
        }
        return (try? LocalizationCatalog(bundle: .module)) ?? LocalizationCatalog(translations: [:])
    }()

    public func text(_ english: String, language: AppLanguage,
                     arguments: [String: String] = [:]) -> String {
        let fallback = translations[.english]?[english].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? english
        let translated = translations[language]?[english].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        // A broken translation must not leak a token or omit a dynamic value.
        let template = translated.flatMap { Self.placeholders(in: $0) == Self.placeholders(in: fallback) ? $0 : nil } ?? fallback
        guard !arguments.isEmpty else { return template }
        // Replace tokens in the template once; argument contents remain literal.
        let source = template as NSString
        var result = template
        for match in Self.tokenPattern.matches(in: template, range: NSRange(location: 0, length: source.length)).reversed() {
            let name = source.substring(with: match.range(at: 1))
            if let value = arguments[name], let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: value)
            }
        }
        return result
    }

    public static func placeholders(in text: String) -> Set<String> {
        let source = text as NSString
        return Set(tokenPattern.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range(at: 1)) })
    }
}
