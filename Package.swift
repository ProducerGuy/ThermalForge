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
            name: "ThermalForgeCore",
            path: "Sources/ThermalForgeCore"
        ),
        .executableTarget(
            name: "thermalforge",
            dependencies: [
                "ThermalForgeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/thermalforge"
        ),
        .testTarget(
            name: "ThermalForgeTests",
            dependencies: ["ThermalForgeCore"],
            path: "Tests/ThermalForgeTests"
        ),
    ]
)
