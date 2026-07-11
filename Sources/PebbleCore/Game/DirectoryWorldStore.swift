import Foundation
import PebbleCoreBase

/// Portable durable world store. Uses atomic files below injected data root;
/// no ambient HOME lookup, SQLite module, or platform framework dependency.
public final class DirectoryWorldStore: WorldStore, @unchecked Sendable {
    private let root: URL
    private let lock = NSRecursiveLock()
    private let fileManager: FileManager

    public init(paths: PebbleDataPaths, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        root = paths.root.appendingPathComponent("world-store", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func listWorlds() -> [WorldRecord] {
        withLock {
            let directory = root.appendingPathComponent("worlds", isDirectory: true)
            let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            return files.compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(WorldRecord.self, from: data)
            }.sorted { $0.lastPlayed > $1.lastPlayed }
        }
    }

    public func getWorld(_ id: String) -> WorldRecord? {
        withLock { decode(WorldRecord.self, from: worldURL(id)) }
    }

    public func putWorld(_ record: WorldRecord) {
        withLock { _ = encode(record, to: worldURL(record.id)) }
    }

    public func deleteWorld(_ id: String) {
        withLock {
            try? fileManager.removeItem(at: worldURL(id))
            try? fileManager.removeItem(at: worldDataDirectory(id))
            let prefix = encodedName(id + "#")
            let playerDirectory = root.appendingPathComponent("players", isDirectory: true)
            let files = (try? fileManager.contentsOfDirectory(at: playerDirectory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix(prefix) { try? fileManager.removeItem(at: file) }
        }
    }

    public func chunkKey(_ worldId: String, _ dim: Int, _ cx: Int, _ cz: Int) -> String {
        "\(worldId):\(dim):\(cx),\(cz)"
    }

    public func getChunkKeys(_ worldId: String) -> Set<String> {
        withLock {
            let directory = chunksDirectory(worldId)
            let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            var keys = Set<String>()
            for file in files where file.pathExtension == "vck" {
                let parts = file.deletingPathExtension().lastPathComponent.split(separator: "_")
                guard parts.count == 3, let dim = Int(parts[0]), let cx = Int(parts[1]), let cz = Int(parts[2]) else { continue }
                keys.insert(chunkKey(worldId, dim, cx, cz))
            }
            return keys
        }
    }

    public func getChunk(_ worldId: String, _ dim: Int, _ cx: Int, _ cz: Int) -> ChunkRecord? {
        withLock {
            guard let data = try? Data(contentsOf: chunkURL(worldId, dim, cx, cz)),
                  let payload = try? VCK1.decode(data),
                  let tail = try? JSONSerialization.jsonObject(with: payload.json) as? [String: Any] else { return nil }
            var record = ChunkRecord(key: chunkKey(worldId, dim, cx, cz), worldId: worldId, dim: dim, cx: cx, cz: cz,
                                     blocks: payload.blocks, biomes: payload.biomes,
                                     entities: tail["entities"] as? [[String: Any]] ?? [])
            if let object = tail["blockEntities"],
               let encoded = try? JSONSerialization.data(withJSONObject: object) {
                record.blockEntities = try? JSONDecoder().decode([BlockEntityData].self, from: encoded)
            }
            return record
        }
    }

    @discardableResult
    public func putChunks(_ records: [ChunkRecord]) -> Bool {
        withLock {
            for record in records {
                var tail: [String: Any] = ["entities": sanitize(record.entities)]
                if let blockEntities = record.blockEntities,
                   let data = try? JSONEncoder().encode(blockEntities),
                   let object = try? JSONSerialization.jsonObject(with: data) {
                    tail["blockEntities"] = object
                }
                guard let json = try? JSONSerialization.data(withJSONObject: tail) else { return false }
                let payload = VCK1Payload(blocks: record.blocks, biomes: record.biomes, json: json)
                guard atomicWrite(VCK1.encode(payload), to: chunkURL(record.worldId, record.dim, record.cx, record.cz)) else { return false }
            }
            return true
        }
    }

    public func getPlayer(_ worldId: String) -> [String: Any]? {
        withLock {
            guard let data = try? Data(contentsOf: playerURL(worldId)) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    public func putPlayer(_ worldId: String, _ data: [String: Any]) {
        withLock {
            guard let bytes = try? JSONSerialization.data(withJSONObject: sanitize(data)) else { return }
            _ = atomicWrite(bytes, to: playerURL(worldId))
        }
    }

    public func getAdvancements(_ worldId: String) -> [String]? {
        withLock { decode([String].self, from: advancementURL(worldId)) }
    }

    public func putAdvancements(_ worldId: String, _ ids: [String]) {
        withLock { _ = encode(ids, to: advancementURL(worldId)) }
    }

    private func worldURL(_ id: String) -> URL {
        root.appendingPathComponent("worlds", isDirectory: true).appendingPathComponent(encodedName(id) + ".json")
    }

    private func worldDataDirectory(_ id: String) -> URL {
        root.appendingPathComponent("data", isDirectory: true).appendingPathComponent(encodedName(id), isDirectory: true)
    }

    private func chunksDirectory(_ id: String) -> URL { worldDataDirectory(id).appendingPathComponent("chunks", isDirectory: true) }
    private func chunkURL(_ id: String, _ dim: Int, _ cx: Int, _ cz: Int) -> URL {
        chunksDirectory(id).appendingPathComponent("\(dim)_\(cx)_\(cz).vck")
    }
    private func playerURL(_ id: String) -> URL {
        root.appendingPathComponent("players", isDirectory: true).appendingPathComponent(encodedName(id) + ".json")
    }
    private func advancementURL(_ id: String) -> URL {
        root.appendingPathComponent("advancements", isDirectory: true).appendingPathComponent(encodedName(id) + ".json")
    }

    private func encodedName(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private func encode<T: Encodable>(_ value: T, to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        return atomicWrite(data, to: url)
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func atomicWrite(_ data: Data, to url: URL) -> Bool {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func sanitize(_ value: Any) -> Any {
        if let number = value as? Double { return number.isFinite ? number : 0 }
        if let array = value as? [Any] { return array.map(sanitize) }
        if let dictionary = value as? [String: Any] { return dictionary.mapValues(sanitize) }
        return value
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
