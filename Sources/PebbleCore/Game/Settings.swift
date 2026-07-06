// Settings — JSON files under ~/Library/Application Support/Pebble/.
// Field names, defaults, and render-distance clamps are frozen; keybinds
// keep internal key-code strings so the app's NSEvent translation layer
// and saved configs stay engine-compatible.

import Foundation

public struct Settings: Codable {
    // video
    public var renderDistance = 8
    public var fov = 70
    public var fancyGraphics = true
    public var smoothLighting = true
    public var bloom = true
    public var shadows = true
    public var clouds = true
    public var particles = 2        // 0 minimal 1 decreased 2 all
    public var gamma = 0.5          // 0..1
    public var viewBobbing = true
    public var guiScale = 0         // 0 auto
    public var maxFps = 120         // 250 = unlimited/vsync-off; opt-in, not the default
    public var entityDistance = 64.0
    // audio
    public var volumes: [String: Double] = [
        "master": 0.8, "music": 0.5, "blocks": 1, "hostile": 1, "friendly": 1,
        "players": 1, "ambient": 1, "records": 1, "ui": 1,
    ]
    // controls
    public var sensitivity = 0.5    // 0..1
    public var invertY = false
    // accessibility
    public var subtitles = false
    public var autoJump = false
    public var reduceMotion = false
    public var reducedFlashes = false
    public var highContrast = false
    public var darknessPulse = 1.0
    /// per-block quads instead of greedy-merged spans (GPU driver workaround)
    public var simpleMesh = false
    /// enabled resource pack file names, index 0 = highest priority.
    /// optional so settings.json files written before this field still decode
    public var resourcePacks: [String]? = nil
    /// nil = off, "ultra" = built-in ultra preset, anything else = shader pack file name
    public var shader: String? = nil
    /// simulation speed multiplier, 0.5–3 (nil = 1×, normal speed).
    /// optional so settings.json files written before this field still decode
    public var gameSpeed: Double? = nil
    /// display name in LAN multiplayer (nil = "Player"); optional for old files
    public var playerName: String? = nil
    /// permanent random identity (like an XUID): names can change, this can't.
    /// servers key inventories by it; friends lists match on it.
    /// generated once at first boot (see GameCore.init); optional for old files
    public var playerId: String? = nil

    public init() {}
}

public let DEFAULT_KEYBINDS: [String: String] = [
    "forward": "KeyW",
    "back": "KeyS",
    "left": "KeyA",
    "right": "KeyD",
    "jump": "Space",
    "sneak": "ShiftLeft",
    "sprint": "ControlLeft",
    "inventory": "KeyE",
    "drop": "KeyQ",
    "chat": "KeyT",
    "command": "Slash",
    "perspective": "F5",
    "swapOffhand": "KeyF",
]

public func defaultSettings() -> Settings { Settings() }

/// ~/Library/Application Support/Pebble — created on first touch
public func vcSupportDir() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("Pebble", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private var settingsURL: URL { vcSupportDir().appendingPathComponent("settings.json") }
private var keybindsURL: URL { vcSupportDir().appendingPathComponent("keybinds.json") }

public func loadSettings() -> Settings {
    var s = Settings()
    if let data = try? Data(contentsOf: settingsURL),
       let saved = try? JSONDecoder().decode(Settings.self, from: data) {
        s = saved
        // merge any volume categories added since the file was written
        for (k, v) in Settings().volumes where s.volumes[k] == nil { s.volumes[k] = v }
    }
    // hard ceiling: above 16 the full-height chunk arrays + mesh pipeline
    // dominate memory; floor of 4 keeps the world visible
    s.renderDistance = min(16, max(4, s.renderDistance))
    if let g = s.gameSpeed { s.gameSpeed = min(3, max(0.5, g)) }
    return s
}

public func saveSettings(_ s: Settings) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(s) {
        try? data.write(to: settingsURL, options: .atomic)
    }
}

public func loadKeybinds() -> [String: String] {
    var binds = DEFAULT_KEYBINDS
    if let data = try? Data(contentsOf: keybindsURL),
       let saved = try? JSONDecoder().decode([String: String].self, from: data) {
        for (k, v) in saved { binds[k] = v }
    }
    return binds
}

public func saveKeybinds(_ binds: [String: String]) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(binds) {
        try? data.write(to: keybindsURL, options: .atomic)
    }
}
