// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ThermalForge",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "ThermalForgeLocalization",
            resources: [.process("Resources")]
        ),
        .target(
            name: "ThermalForgeCore",
            path: "Sources/ThermalForgeCore",
            linkerSettings: [
                .linkedFramework("Metal"),
            ]
        ),
        .executableTarget(
            name: "thermalforge",
            dependencies: [
                "ThermalForgeCore",
                "ThermalForgeLocalization",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/thermalforge"
        ),
        .executableTarget(
            name: "ThermalForgeApp",
            dependencies: ["ThermalForgeCore", "ThermalForgeLocalization"],
            path: "Sources/ThermalForgeApp"
        ),
        .testTarget(
            name: "ThermalForgeTests",
            dependencies: ["ThermalForgeCore", "ThermalForgeApp", "ThermalForgeLocalization"],
            path: "Tests/ThermalForgeTests"
        ),
    ]
)
