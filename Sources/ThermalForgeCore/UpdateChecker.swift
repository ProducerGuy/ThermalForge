//
//  UpdateChecker.swift
//  ThermalForge
//
//  Daily "is there a newer release?" check against the GitHub releases API. The
//  app already knows its own version; this tells it when a newer one has shipped
//  so a user still on an old build finds out without happening to run
//  `brew upgrade`. It sends nothing about the user — a plain unauthenticated GET
//  to a public endpoint, the same request anyone loading the repo page makes.
//
//  Two halves, split so the comparison is unit-testable without a network:
//    - evaluate(...)  pure: given the current version + a release tag, decide.
//    - check(...)     async: fetch /releases/latest and run evaluate on it.
//
//  The check is SILENT on every failure. It returns `.failed` (never a spurious
//  `.upToDate`) so the caller leaves any prior state untouched and never shows a
//  banner off a check that didn't actually complete — offline, rate-limited, and
//  GitHub-down all look the same and all do nothing.
//

import Foundation

/// A release strictly newer than what's installed.
public struct AvailableUpdate: Equatable, Sendable {
    /// The release version, already stripped of any leading "v" (e.g. "0.2.2").
    public let version: String
    /// The release's page URL, for a "What's new" link.
    public let url: String

    public init(version: String, url: String) {
        self.version = version
        self.url = url
    }
}

/// Outcome of an update check. Three states, not an optional, so a *failed* check
/// (leave prior state) is distinct from a *successful* "you're current" (clear any
/// stale banner). The banner shows only for `.update`.
public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case update(AvailableUpdate)
    case failed
}

public enum UpdateChecker {
    /// `/releases/latest` returns the newest release EXCLUDING drafts and
    /// prereleases, so only stable releases we actually cut can ever surface.
    public static let releasesAPIURL = URL(string: "https://api.github.com/repos/ProducerGuy/ThermalForge/releases/latest")!
    /// Fallback "What's new" link when a persisted check has no stored URL.
    public static let releasesPageURL = "https://github.com/ProducerGuy/ThermalForge/releases/latest"

    /// Pure comparison. Returns an AvailableUpdate iff `tagName` is a strictly newer
    /// version than `current`, else nil.
    ///
    /// Strips a single leading "v" first: `ThermalForgeVersion.atLeast` Int-parses on
    /// dots, and "v0" parses to nil → 0, so "v0.2.1" would compare as 0.2.1's first
    /// component being 0. A malformed tag (e.g. "vX.Y") therefore degrades to 0.0 and
    /// yields nil — it can never produce a false "update available".
    public static func evaluate(current: String, tagName: String, url: String) -> AvailableUpdate? {
        let tag = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        guard !tag.isEmpty else { return nil }
        // Newer iff current is NOT already >= tag.
        guard !ThermalForgeVersion.atLeast(current, tag) else { return nil }
        return AvailableUpdate(version: tag, url: url)
    }

    /// Minimal decode of the fields we use; extra JSON keys are ignored.
    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String?
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    /// Fetch the latest release and evaluate it. `.failed` on ANY error (offline,
    /// non-200, rate limited, malformed) so the caller can stay silent; the session
    /// is injectable for tests.
    public static func check(current: String = ThermalForgeVersion.current,
                             session: URLSession = .shared) async -> UpdateCheckResult {
        var request = URLRequest(url: releasesAPIURL, timeoutInterval: 10)
        // GitHub rejects API requests without a User-Agent; Accept pins the v3 JSON.
        request.setValue("ThermalForge/\(current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data)
        else {
            return .failed
        }

        if let update = evaluate(current: current,
                                 tagName: release.tagName,
                                 url: release.htmlURL ?? releasesPageURL) {
            return .update(update)
        }
        return .upToDate
    }
}
