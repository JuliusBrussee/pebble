import Foundation

/// Process-local store for embedded clients, deterministic sessions, and
/// servers whose host owns persistence. All snapshots are isolated by lock.
public final class MemoryWorldStore: WorldStore, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var worlds: [String: WorldRecord] = [:]
    private var chunks: [String: ChunkRecord] = [:]
    private var players: [String: [String: Any]] = [:]
    private var advancements: [String: [String]] = [:]

    public init() {}

    public func listWorlds() -> [WorldRecord] {
        withLock { worlds.values.sorted { $0.lastPlayed > $1.lastPlayed } }
    }

    public func getWorld(_ id: String) -> WorldRecord? {
        withLock { worlds[id] }
    }

    public func putWorld(_ record: WorldRecord) {
        withLock { worlds[record.id] = record }
    }

    public func deleteWorld(_ id: String) {
        withLock {
            worlds.removeValue(forKey: id)
            chunks = chunks.filter { $0.value.worldId != id }
            players = players.filter { key, _ in key != id && !key.hasPrefix(id + "#") }
            advancements.removeValue(forKey: id)
        }
    }

    public func chunkKey(_ worldId: String, _ dim: Int, _ cx: Int, _ cz: Int) -> String {
        "\(worldId):\(dim):\(cx),\(cz)"
    }

    public func getChunkKeys(_ worldId: String) -> Set<String> {
        withLock { Set(chunks.values.lazy.filter { $0.worldId == worldId }.map(\.key)) }
    }

    public func getChunk(_ worldId: String, _ dim: Int, _ cx: Int, _ cz: Int) -> ChunkRecord? {
        withLock { chunks[chunkKey(worldId, dim, cx, cz)] }
    }

    @discardableResult
    public func putChunks(_ records: [ChunkRecord]) -> Bool {
        withLock {
            for record in records { chunks[record.key] = record }
            return true
        }
    }

    public func getPlayer(_ worldId: String) -> [String: Any]? {
        withLock { players[worldId] }
    }

    public func putPlayer(_ worldId: String, _ data: [String: Any]) {
        withLock { players[worldId] = data }
    }

    public func getAdvancements(_ worldId: String) -> [String]? {
        withLock { advancements[worldId] }
    }

    public func putAdvancements(_ worldId: String, _ ids: [String]) {
        withLock { advancements[worldId] = ids }
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
