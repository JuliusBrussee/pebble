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
        .library(name: "PebbleRenderABI", targets: ["PebbleRenderABI"]),
        .library(name: "PebbleCodecs", targets: ["PebbleCodecs"]),
        .library(name: "PebbleAudioCore", targets: ["PebbleAudioCore"]),
        .library(name: "PebblePlatformNative", targets: ["PebblePlatformNative"]),
        .library(name: "PebbleStoreSQLite", targets: ["PebbleStoreSQLite"]),
        .library(name: "PebbleNetApple", targets: ["PebbleNetApple"]),
        .executable(name: "Pebble", targets: ["Pebble"]),
        .executable(name: "pebserver", targets: ["pebserver"]),
        .executable(name: "pebsmoke", targets: ["pebsmoke"]),
        .executable(name: "pebsmoke-deterministic", targets: ["pebsmoke_deterministic"]),
        .executable(name: "pebsmoke-portable", targets: ["pebsmoke_portable"]),
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
        // portable render ABI: neutral frame/draw packets, no Metal/Vulkan types. placeholder until lane D.
        .target(
            name: "PebbleRenderABI",
            dependencies: ["PebbleCoreBase"],
            path: "Sources/PebbleRenderABI",
            swiftSettings: swift5
        ),
        // portable codecs (PNG/ZIP/etc.): no ImageIO/Compression. placeholder until lane E.
        .target(
            name: "PebbleCodecs",
            dependencies: ["PebbleCoreBase"],
            path: "Sources/PebbleCodecs",
            swiftSettings: swift5
        ),
        // portable audio core: no AVFoundation/miniaudio linkage yet. placeholder until lane E.
        .target(
            name: "PebbleAudioCore",
            dependencies: ["PebbleCoreBase"],
            path: "Sources/PebbleAudioCore",
            swiftSettings: swift5
        ),
        // thin portable Swift wrapper over the CPebblePlatform C ABI.
        .target(
            name: "PebblePlatformNative",
            dependencies: ["CPebblePlatform"],
            path: "Sources/PebblePlatformNative",
            swiftSettings: swift5
        ),
        // the engine: headless-testable, no AppKit dependencies
        .target(
            name: "PebbleCore",
            dependencies: ["PebbleRenderABI"],
            path: "Sources/PebbleCore",
            swiftSettings: swift5
        ),
        // macOS-only SQLite-backed world store. EMPTY placeholder — lane B fills this in.
        .target(
            name: "PebbleStoreSQLite",
            dependencies: ["PebbleCore"],
            path: "Sources/PebbleStoreSQLite",
            swiftSettings: swift5,
            linkerSettings: [
                .linkedLibrary("sqlite3", .when(platforms: [.macOS])),
            ]
        ),
        // macOS-only Network.framework transport adapter. EMPTY placeholder — lane C fills this in.
        .target(
            name: "PebbleNetApple",
            dependencies: ["PebbleCore"],
            path: "Sources/PebbleNetApple",
            swiftSettings: swift5
        ),
        // the app: AppKit + MTKView shell
        .executableTarget(
            name: "Pebble",
            dependencies: [
                "PebbleCore",
                "PebbleRenderABI",
                "PebbleCodecs",
                "PebbleAudioCore",
                .target(name: "PebbleStoreSQLite", condition: .when(platforms: [.macOS])),
                .target(name: "PebbleNetApple", condition: .when(platforms: [.macOS])),
            ],
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
            dependencies: [
                "PebbleCore",
                .target(name: "PebbleStoreSQLite", condition: .when(platforms: [.macOS])),
                .target(name: "PebbleNetApple", condition: .when(platforms: [.macOS])),
            ],
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
        // portable smoke harness: fail-closed, no PebbleCore-only Apple-only deps required to build.
        .executableTarget(
            name: "pebsmoke_portable",
            dependencies: [
                "PebbleCoreBase",
                "CPebblePlatform",
                "PebblePlatformNative",
                "PebbleRenderABI",
                "PebbleCodecs",
                "PebbleAudioCore",
                "PebbleCore",
            ],
            path: "Sources/pebsmoke_portable",
            swiftSettings: swift5
        ),
        // dedicated LAN/SMP server: runs a world headless, no host player
        .executableTarget(
            name: "pebserver",
            dependencies: [
                "PebbleCore",
                .target(name: "PebbleStoreSQLite", condition: .when(platforms: [.macOS])),
                .target(name: "PebbleNetApple", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/pebserver",
            swiftSettings: swift5
        ),
    ]
)
