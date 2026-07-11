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
        .library(name: "PebbleResources", targets: ["PebbleResources"]),
        .library(name: "PebbleAudioCore", targets: ["PebbleAudioCore"]),
        .library(name: "PebblePlatformNative", targets: ["PebblePlatformNative"]),
        .library(name: "PebbleStoreSQLite", targets: ["PebbleStoreSQLite"]),
        .library(name: "PebbleNetApple", targets: ["PebbleNetApple"]),
        .library(name: "PebbleNetNative", targets: ["PebbleNetNative"]),
        .library(name: "PebbleRendererVulkan", targets: ["PebbleRendererVulkan"]),
        .library(name: "PebblePlatformSDL", targets: ["PebblePlatformSDL"]),
        .library(name: "PebbleUI", targets: ["PebbleUI"]),
        .executable(name: "Pebble", targets: ["Pebble"]),
        .executable(name: "pebserver", targets: ["pebserver"]),
        .executable(name: "pebsmoke", targets: ["pebsmoke"]),
        .executable(name: "pebsmoke-deterministic", targets: ["pebsmoke_deterministic"]),
        .executable(name: "pebsmoke-portable", targets: ["pebsmoke_portable"]),
        .executable(name: "pebvk", targets: ["pebvk"]),
        .executable(name: "pebble-win", targets: ["pebble_win"]),
    ],
    targets: [
        // portable deterministic primitives used by selected cross-platform smoke.
        // Keep these files in sync with Sources/PebbleCore/Core until PebbleCore is fully split.
        .target(
            name: "PebbleCoreBase",
            path: "Sources/PebbleCoreBase",
            swiftSettings: swift5
        ),
        // Cross-platform C ABI for native sockets/audio and platform capabilities.
        .target(
            name: "CPebblePlatform",
            path: "Sources/CPebblePlatform",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AudioToolbox", .when(platforms: [.macOS])),
                .linkedLibrary("winmm", .when(platforms: [.windows])),
            ]
        ),
        // portable render ABI: neutral frame/draw packets, no Metal/Vulkan types.
        .target(
            name: "PebbleRenderABI",
            dependencies: ["PebbleCoreBase"],
            path: "Sources/PebbleRenderABI",
            exclude: ["README.md"],
            swiftSettings: swift5
        ),
        // portable codecs (PNG/ZIP/etc.): no ImageIO/Compression.
        .target(
            name: "PebbleCodecs",
            dependencies: ["PebbleCoreBase"],
            path: "Sources/PebbleCodecs",
            swiftSettings: swift5
        ),
        .target(
            name: "PebbleResources",
            dependencies: ["PebbleCodecs", "PebbleCore"],
            path: "Sources/PebbleResources",
            swiftSettings: swift5
        ),
        // portable audio mixer and shared native-output facade.
        .target(
            name: "PebbleAudioCore",
            dependencies: ["PebbleCoreBase", "PebblePlatformNative"],
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
            dependencies: ["PebbleCoreBase", "PebbleRenderABI"],
            path: "Sources/PebbleCore",
            swiftSettings: swift5
        ),
        // macOS SQLite world-store adapter.
        .target(
            name: "PebbleStoreSQLite",
            dependencies: ["PebbleCore", "PebbleCoreBase"],
            path: "Sources/PebbleStoreSQLite",
            swiftSettings: swift5,
            linkerSettings: [
                .linkedLibrary("sqlite3", .when(platforms: [.macOS])),
            ]
        ),
        // macOS Network.framework TCP/Bonjour adapter.
        .target(
            name: "PebbleNetApple",
            dependencies: ["PebbleCore"],
            path: "Sources/PebbleNetApple",
            swiftSettings: swift5
        ),
        .target(
            name: "PebbleNetNative",
            dependencies: ["PebbleCore", "PebblePlatformNative"],
            path: "Sources/PebbleNetNative",
            swiftSettings: swift5
        ),
        .target(
            name: "CPebbleVulkan",
            path: "Sources/CPebbleVulkan",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("vulkan")]
        ),
        .target(
            name: "PebbleRendererVulkan",
            dependencies: ["CPebbleVulkan", "PebbleRenderABI"],
            path: "Sources/PebbleRendererVulkan",
            swiftSettings: swift5
        ),
        .target(
            name: "CPebbleSDL",
            path: "Sources/CPebbleSDL",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("SDL3"), .linkedLibrary("vulkan")]
        ),
        .target(
            name: "PebblePlatformSDL",
            dependencies: ["CPebbleSDL"],
            path: "Sources/PebblePlatformSDL",
            swiftSettings: swift5
        ),
        .target(
            name: "PebbleUI",
            dependencies: ["PebbleRenderABI"],
            path: "Sources/PebbleUI",
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
                "PebblePlatformNative",
                .target(name: "PebbleStoreSQLite", condition: .when(platforms: [.macOS])),
                .target(name: "PebbleNetApple", condition: .when(platforms: [.macOS])),
                "PebbleNetNative",
            ],
            path: "Sources/Pebble",
            swiftSettings: swift5,
            linkerSettings: [
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("Metal", .when(platforms: [.macOS])),
                .linkedFramework("MetalKit", .when(platforms: [.macOS])),
                .linkedFramework("QuartzCore", .when(platforms: [.macOS])),
            ]
        ),
        // headless smoke tests against the frozen golden baselines
        .executableTarget(
            name: "pebsmoke",
            dependencies: [
                "PebbleCore",
                .target(name: "PebbleStoreSQLite", condition: .when(platforms: [.macOS])),
                .target(name: "PebbleNetApple", condition: .when(platforms: [.macOS])),
                "PebbleNetNative",
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
                "PebbleNetNative",
            ],
            path: "Sources/pebserver",
            swiftSettings: swift5
        ),
        .executableTarget(
            name: "pebvk",
            dependencies: ["PebbleRendererVulkan", "PebbleRenderABI", "PebbleCodecs"],
            path: "Sources/pebvk",
            swiftSettings: swift5
        ),
        .executableTarget(
            name: "pebble_win",
            dependencies: ["PebbleCore", "PebbleAudioCore", "PebbleRenderABI", "PebbleRendererVulkan", "PebblePlatformSDL", "PebbleNetNative", "PebbleUI", "PebbleResources", "PebbleCodecs"],
            path: "Sources/pebble_win",
            swiftSettings: swift5
        ),
    ]
)
