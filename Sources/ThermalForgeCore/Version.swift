//
//  Version.swift
//  ThermalForge
//
//  Single source of truth for the ThermalForge version. Referenced by the CLI
//  `--version`, the logged session metadata, the daemon's `version` command,
//  and the CLI's daemon-version reconciliation check — so all four can never
//  drift apart within a build.
//

public enum ThermalForgeVersion {
    public static let current = "0.1.4"

    /// Minimum macOS version, as written into the app bundle's Info.plist
    /// (LSMinimumSystemVersion) by `build-app`. Kept here so the assembler has
    /// no hardcoded field.
    ///
    /// This is the SAME floor as two build/packaging manifests that cannot
    /// import this constant and so must be kept in sync by hand:
    ///   - Package.swift          → `.macOS(.v14)`  (SPM manifest, evaluated
    ///                              standalone before this module is built)
    ///   - Homebrew formula       → `depends_on macos: :sonoma`  (Ruby, tap repo)
    /// All three currently mean macOS 14 (Sonoma).
    public static let minimumMacOS = "14.0"
}
