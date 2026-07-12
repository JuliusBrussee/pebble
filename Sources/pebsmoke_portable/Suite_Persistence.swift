import Foundation
import PebbleCore

public struct PersistenceSuite: PortableSuite {
    public static let name = "persistence"

    public static func run(_ h: inout SmokeHarness) {
        exercise(PebbleCore.MemoryWorldStore(), label: "memory", h: &h)

        let base = ProcessInfo.processInfo.environment["PEBBLE_DATA_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("persistence-suite-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let paths = try PebbleCore.PebbleDataPaths(root: root)
            let first = try PebbleCore.DirectoryWorldStore(paths: paths)
            exercise(first, label: "directory", h: &h, deleteAtEnd: false)

            let reopened = try PebbleCore.DirectoryWorldStore(paths: paths)
            h.eq("directory survives reopen world", reopened.getWorld("world")?.name, "Test World")
            h.eq("directory survives reopen chunks", reopened.getChunkKeys("world"), Set(["world:0:-2,3"]))
            h.eq("directory survives reopen player", reopened.getPlayer("world")?["name"] as? String, "Alex")
            h.eq("directory survives reopen advancements", reopened.getAdvancements("world"), ["story/root", "story/mine_stone"])
            verifyDelete(reopened, label: "directory", h: &h)
        } catch {
            h.check("directory store initializes", false)
        }
    }

    private static func exercise(_ store: any PebbleCore.WorldStore,
                                 label: String,
                                 h: inout SmokeHarness,
                                 deleteAtEnd: Bool = true) {
        let old = PebbleCore.WorldRecord(id: "old", name: "Older", seed: 1, gameMode: 0,
                                         difficulty: 1, lastPlayed: 10)
        var world = PebbleCore.WorldRecord(id: "world", name: "Test World", seed: -42,
                                           gameMode: 1, difficulty: 3, lastPlayed: 20)
        world.spawnX = 12
        world.gameRules = ["keepInventory": 1]
        store.putWorld(old)
        store.putWorld(world)
        h.eq("\(label) world round-trip name", store.getWorld("world")?.name, world.name)
        h.eq("\(label) world round-trip seed", store.getWorld("world")?.seed, world.seed)
        h.eq("\(label) world round-trip spawn", store.getWorld("world")?.spawnX, 12)
        h.eq("\(label) worlds sort newest first", store.listWorlds().map(\.id), ["world", "old"])

        let key = store.chunkKey("world", 0, -2, 3)
        let chunk = PebbleCore.ChunkRecord(
            key: key, worldId: "world", dim: 0, cx: -2, cz: 3,
            blocks: [0, 1, UInt16.max], biomes: [4, 7],
            entities: [["id": "pig", "health": 10.0], ["velocity": Double.infinity]])
        h.check("\(label) chunk write succeeds", store.putChunks([chunk]))
        h.eq("\(label) chunk key listed", store.getChunkKeys("world"), Set([key]))
        let loaded = store.getChunk("world", 0, -2, 3)
        h.eq("\(label) chunk blocks", loaded?.blocks, chunk.blocks)
        h.eq("\(label) chunk biomes", loaded?.biomes, chunk.biomes)
        h.eq("\(label) chunk entity id", loaded?.entities.first?["id"] as? String, "pig")

        store.putPlayer("world", ["name": "Alex", "health": 20.0, "bad": Double.nan])
        h.eq("\(label) player string", store.getPlayer("world")?["name"] as? String, "Alex")
        store.putPlayer("world#guest", ["name": "Guest"])
        store.putAdvancements("world", ["story/root", "story/mine_stone"])
        h.eq("\(label) advancements", store.getAdvancements("world"), ["story/root", "story/mine_stone"])

        if deleteAtEnd { verifyDelete(store, label: label, h: &h) }
    }

    private static func verifyDelete(_ store: any PebbleCore.WorldStore,
                                     label: String,
                                     h: inout SmokeHarness) {
        store.deleteWorld("world")
        h.check("\(label) delete world", store.getWorld("world") == nil)
        h.check("\(label) delete chunks", store.getChunkKeys("world").isEmpty)
        h.check("\(label) delete player", store.getPlayer("world") == nil)
        h.check("\(label) delete guest player", store.getPlayer("world#guest") == nil)
        h.check("\(label) delete advancements", store.getAdvancements("world") == nil)
        h.eq("\(label) delete preserves other worlds", store.getWorld("old")?.name, "Older")
    }
}
