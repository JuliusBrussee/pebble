import Foundation

public enum PebbleDataPathError: Error, CustomStringConvertible {
    case missingDataRootInCI
    case emptyDataRoot

    public var description: String {
        switch self {
        case .missingDataRootInCI:
            return "PEBBLE_DATA_DIR or --data-root is required in CI before Pebble storage can be opened"
        case .emptyDataRoot:
            return "Pebble data root is empty"
        }
    }
}

public struct PebbleDataPaths: Sendable {
    public let root: URL

    public init(root: URL, create: Bool = true) throws {
        let standardized = root.standardizedFileURL
        guard !standardized.path.isEmpty else { throw PebbleDataPathError.emptyDataRoot }
        self.root = standardized
        if create {
            try FileManager.default.createDirectory(at: standardized, withIntermediateDirectories: true)
        }
    }

    public static func resolve(explicit: URL? = nil,
                               env: [String: String] = ProcessInfo.processInfo.environment,
                               create: Bool = true) throws -> PebbleDataPaths {
        if let explicit {
            return try PebbleDataPaths(root: explicit, create: create)
        }
        if let raw = env["PEBBLE_DATA_DIR"], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try PebbleDataPaths(root: URL(fileURLWithPath: raw), create: create)
        }
        if env["PEBBLE_CI"] == "1" || env["CI"] != nil || env["GITHUB_ACTIONS"] != nil {
            throw PebbleDataPathError.missingDataRootInCI
        }
        return try PebbleDataPaths(root: platformDefaultRoot(), create: create)
    }

    public static func platformDefault() -> PebbleDataPaths {
        do {
            return try resolve(create: true)
        } catch {
            fatalError("Pebble data root unavailable: \(error)")
        }
    }

    public static func platformDefaultRoot() -> URL {
        #if os(Windows)
        let env = ProcessInfo.processInfo.environment
        if let local = env["LOCALAPPDATA"], !local.isEmpty {
            return URL(fileURLWithPath: local).appendingPathComponent("Pebble", isDirectory: true)
        }
        if let appData = env["APPDATA"], !appData.isEmpty {
            return URL(fileURLWithPath: appData).appendingPathComponent("Pebble", isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("PebbleData", isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pebble", isDirectory: true)
        #endif
    }

    public var database: URL { root.appendingPathComponent("pebble.db") }
    public var settingsJSON: URL { root.appendingPathComponent("settings.json") }
    public var keybindsJSON: URL { root.appendingPathComponent("keybinds.json") }
    public var legacySavesDir: URL { root.appendingPathComponent("saves", isDirectory: true) }
    public var legacyBackupDir: URL { root.appendingPathComponent("saves-legacy-backup", isDirectory: true) }
    public var resourcePacksDir: URL { root.appendingPathComponent("resourcepacks", isDirectory: true) }
    public var skinPNG: URL { root.appendingPathComponent("skin.png") }

    public func socialJSON(_ file: String) -> URL {
        root.appendingPathComponent(file)
    }
}

public struct EngineServices {
    public let paths: PebbleDataPaths
    public let settingsStore: SettingsStore
    public let db: SaveDB
    public let socialStore: SocialStore
    public let nowMillis: () -> Double
    public let makeUUIDString: () -> String
    public let randomInt: (Int) -> Int

    public init(paths: PebbleDataPaths,
                nowMillis: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
                makeUUIDString: @escaping () -> String = { UUID().uuidString },
                randomInt: @escaping (Int) -> Int = { upperBound in Int.random(in: 0..<upperBound) }) {
        self.paths = paths
        self.nowMillis = nowMillis
        self.makeUUIDString = makeUUIDString
        self.randomInt = randomInt
        self.settingsStore = SettingsStore(paths: paths)
        self.db = SaveDB(paths: paths)
        self.socialStore = SocialStore(paths: paths, clock: nowMillis)
    }

    public static func live(paths: PebbleDataPaths) -> EngineServices {
        EngineServices(paths: paths)
    }

    public static func platformDefault() -> EngineServices {
        EngineServices(paths: .platformDefault())
    }
}
