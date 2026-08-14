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
    public static let current = "0.1.3"
}
