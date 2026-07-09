// swift-tools-version: 6.0
// Pebble — a native Swift + Metal block-survival game for macOS.
// CLI-only workflow: swift build -c release. No .xcodeproj.

import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Pebble",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PebbleCoreBase", targets: ["PebbleCoreBase"]),
        .library(name: "PebbleCore", targets: ["PebbleCore"]),
        .library(name: "CPebblePlatform", targets: ["CPebblePlatform"]),
        .executable(name: "Pebble", targets: ["Pebble"]),
        .executable(name: "pebserver", targets: ["pebserver"]),
        .executable(name: "pebsmoke", targets: ["pebsmoke"]),
        .executable(name: "pebsmoke-deterministic", targets: ["pebsmoke_deterministic"]),
    ],
    targets: [
        // portable deterministic primitives used by selected cross-platform smoke.
        // Keep these files in sync with Sources/PebbleCore/Core until PebbleCore is fully split.
        .target(
            name: "PebbleCoreBase",
            path: "Sources/PebbleCoreBase",
            swiftSettings: swift5
        ),
        // C ABI skeleton for future Vulkan/SDL/miniaudio/sockets/codecs adapters.
        .target(
            name: "CPebblePlatform",
            path: "Sources/CPebblePlatform",
            publicHeadersPath: "include"
        ),
        // the engine: headless-testable, no AppKit dependencies
        .target(
            name: "PebbleCore",
            path: "Sources/PebbleCore",
            swiftSettings: swift5
        ),
        // the app: AppKit + MTKView shell
        .executableTarget(
            name: "Pebble",
            dependencies: ["PebbleCore"],
            path: "Sources/Pebble",
            swiftSettings: swift5,
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("Metal", .when(platforms: [.macOS])),
                .linkedFramework("MetalKit", .when(platforms: [.macOS])),
                .linkedFramework("QuartzCore", .when(platforms: [.macOS])),
                .linkedFramework("AVFoundation", .when(platforms: [.macOS])),
            ]
        ),
        // headless smoke tests against the frozen golden baselines
        .executableTarget(
            name: "pebsmoke",
            dependencies: ["PebbleCore"],
            path: "Sources/pebsmoke",
            swiftSettings: swift5
        ),
        // deterministic-only selected smoke: no GameCore, storage, network, app, or resources.
        .executableTarget(
            name: "pebsmoke_deterministic",
            dependencies: ["PebbleCoreBase"],
            path: "Sources/pebsmoke_deterministic",
            swiftSettings: swift5
        ),
        // dedicated LAN/SMP server: runs a world headless, no host player
        .executableTarget(
            name: "pebserver",
            dependencies: ["PebbleCore"],
            path: "Sources/pebserver",
            swiftSettings: swift5
        ),
    ]
)
