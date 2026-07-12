import Foundation
import SQLite3
import PebbleCore
import PebbleCoreBase

public struct SQLiteWorldStoreError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteWorldStore: WorldStore, @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(paths: PebbleDataPaths) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(paths.database.path, &database, flags, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            if let database { sqlite3_close(database) }
            throw SQLiteWorldStoreError(message: "pebble.db could not be opened: \(message)")
        }
        guard execute("PRAGMA journal_mode=WAL"),
              execute("PRAGMA synchronous=NORMAL"),
              execute("PRAGMA busy_timeout=5000"),
              execute("CREATE TABLE IF NOT EXISTS worlds(id TEXT PRIMARY KEY, json TEXT NOT NULL, lastPlayed REAL NOT NULL DEFAULT 0)"),
              execute("CREATE TABLE IF NOT EXISTS chunks(world TEXT NOT NULL, dim INTEGER NOT NULL, cx INTEGER NOT NULL, cz INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY(world, dim, cx, cz)) WITHOUT ROWID"),
              execute("CREATE TABLE IF NOT EXISTS player(world TEXT PRIMARY KEY, json TEXT NOT NULL)"),
              execute("CREATE TABLE IF NOT EXISTS advancements(world TEXT PRIMARY KEY, json TEXT NOT NULL)") else {
            let message = lastError()
            sqlite3_close(database)
            database = nil
            throw SQLiteWorldStoreError(message: "pebble.db schema initialization failed: \(message)")
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    public func listWorlds() -> [WorldRecord] {
        withLock {
            var records: [WorldRecord] = []
            query("SELECT json FROM worlds ORDER BY lastPlayed DESC", row: { statement in
                if let json = self.text(statement, 0),
                   let record = try? JSONDecoder().decode(WorldRecord.self, from: Data(json.utf8)) {
                    records.append(record)
                }
            })
            return records
        }
    }

    public func getWorld(_ id: String) -> WorldRecord? {
        withLock {
            var record: WorldRecord?
            query("SELECT json FROM worlds WHERE id=?", bind: { self.bind($0, 1, id) }) { statement in
                guard let json = self.text(statement, 0) else { return }
                record = try? JSONDecoder().decode(WorldRecord.self, from: Data(json.utf8))
            }
            return record
        }
    }

    public func putWorld(_ record: WorldRecord) {
        withLock {
            guard let bytes = try? JSONEncoder().encode(record), let json = String(data: bytes, encoding: .utf8) else { return }
            query("INSERT OR REPLACE INTO worlds(id,json,lastPlayed) VALUES(?,?,?)", bind: { statement in
                self.bind(statement, 1, record.id)
                self.bind(statement, 2, json)
                sqlite3_bind_double(statement, 3, record.lastPlayed)
            })
        }
    }

    public func deleteWorld(_ id: String) {
        withLock {
            guard execute("BEGIN IMMEDIATE") else { return }
            var success = true
            for table in ["worlds", "chunks", "player", "advancements"] {
                let column = table == "worlds" ? "id" : "world"
                success = query("DELETE FROM \(table) WHERE \(column)=?", bind: { self.bind($0, 1, id) }) && success
            }
            success = query("DELETE FROM player WHERE world LIKE ?", bind: { self.bind($0, 1, id + "#%") }) && success
            _ = execute(success ? "COMMIT" : "ROLLBACK")
        }
    }

    public func chunkKey(_ worldId: String, _ dim: Int, _ cx: Int, _ cz: Int) -> String {
        "\(worldId):\(dim):\(cx),\(cz)"
    }

    public func getChunkKeys(_ worldId: String) -> Set<String> {
        withLock {
            var keys = Set<String>()
            query("SELECT dim,cx,cz FROM chunks WHERE world=?", bind: { self.bind($0, 1, worldId) }) { statement in
                keys.insert(self.chunkKey(worldId, Int(sqlite3_column_int(statement, 0)),
                                          Int(sqlite3_column_int(statement, 1)), Int(sqlite3_column_int(statement, 2))))
            }
            return keys
        }
    }

    public func getChunk(_ worldId: String, _ dim: Int, _ cx: Int, _ cz: Int) -> ChunkRecord? {
        withLock {
            var record: ChunkRecord?
            query("SELECT data FROM chunks WHERE world=? AND dim=? AND cx=? AND cz=?", bind: { statement in
                self.bind(statement, 1, worldId)
                sqlite3_bind_int(statement, 2, Int32(dim))
                sqlite3_bind_int(statement, 3, Int32(cx))
                sqlite3_bind_int(statement, 4, Int32(cz))
            }) { statement in
                guard let pointer = sqlite3_column_blob(statement, 0) else { return }
                let data = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
                record = self.decodeChunk(data, worldId: worldId, dim: dim, cx: cx, cz: cz)
            }
            return record
        }
    }

    @discardableResult
    public func putChunks(_ records: [ChunkRecord]) -> Bool {
        withLock {
            guard !records.isEmpty else { return true }
            guard execute("BEGIN IMMEDIATE") else { return false }
            var success = true
            for record in records {
                guard let data = encodeChunk(record) else { success = false; break }
                success = query("INSERT OR REPLACE INTO chunks(world,dim,cx,cz,data) VALUES(?,?,?,?,?)", bind: { statement in
                    self.bind(statement, 1, record.worldId)
                    sqlite3_bind_int(statement, 2, Int32(record.dim))
                    sqlite3_bind_int(statement, 3, Int32(record.cx))
                    sqlite3_bind_int(statement, 4, Int32(record.cz))
                    data.withUnsafeBytes { bytes in
                        _ = sqlite3_bind_blob(statement, 5, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
                    }
                })
                if !success { break }
            }
            if !execute(success ? "COMMIT" : "ROLLBACK") { return false }
            return success
        }
    }

    public func getPlayer(_ worldId: String) -> [String: Any]? {
        withLock {
            var result: [String: Any]?
            query("SELECT json FROM player WHERE world=?", bind: { self.bind($0, 1, worldId) }) { statement in
                guard let json = self.text(statement, 0) else { return }
                result = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            }
            return result
        }
    }

    public func putPlayer(_ worldId: String, _ data: [String: Any]) {
        withLock {
            guard let bytes = try? JSONSerialization.data(withJSONObject: sanitize(data)),
                  let json = String(data: bytes, encoding: .utf8) else { return }
            query("INSERT OR REPLACE INTO player(world,json) VALUES(?,?)", bind: {
                self.bind($0, 1, worldId); self.bind($0, 2, json)
            })
        }
    }

    public func getAdvancements(_ worldId: String) -> [String]? {
        withLock {
            var result: [String]?
            query("SELECT json FROM advancements WHERE world=?", bind: { self.bind($0, 1, worldId) }) { statement in
                guard let json = self.text(statement, 0) else { return }
                result = try? JSONDecoder().decode([String].self, from: Data(json.utf8))
            }
            return result
        }
    }

    public func putAdvancements(_ worldId: String, _ ids: [String]) {
        withLock {
            guard let bytes = try? JSONEncoder().encode(ids), let json = String(data: bytes, encoding: .utf8) else { return }
            query("INSERT OR REPLACE INTO advancements(world,json) VALUES(?,?)", bind: {
                self.bind($0, 1, worldId); self.bind($0, 2, json)
            })
        }
    }

    private func encodeChunk(_ record: ChunkRecord) -> Data? {
        var tail: [String: Any] = ["entities": sanitize(record.entities)]
        if let entities = record.blockEntities,
           let data = try? JSONEncoder().encode(entities),
           let object = try? JSONSerialization.jsonObject(with: data) { tail["blockEntities"] = object }
        guard let json = try? JSONSerialization.data(withJSONObject: tail) else { return nil }
        return VCK1.encode(VCK1Payload(blocks: record.blocks, biomes: record.biomes, json: json))
    }

    private func decodeChunk(_ data: Data, worldId: String, dim: Int, cx: Int, cz: Int) -> ChunkRecord? {
        guard let payload = try? VCK1.decode(data),
              let tail = try? JSONSerialization.jsonObject(with: payload.json) as? [String: Any] else { return nil }
        var record = ChunkRecord(key: chunkKey(worldId, dim, cx, cz), worldId: worldId, dim: dim, cx: cx, cz: cz,
                                 blocks: payload.blocks, biomes: payload.biomes,
                                 entities: tail["entities"] as? [[String: Any]] ?? [])
        if let object = tail["blockEntities"],
           let bytes = try? JSONSerialization.data(withJSONObject: object) {
            record.blockEntities = try? JSONDecoder().decode([BlockEntityData].self, from: bytes)
        }
        return record
    }

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }

    @discardableResult
    private func query(_ sql: String,
                       bind: ((OpaquePointer) -> Void)? = nil,
                       row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        bind?(statement)
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { row?(statement); result = sqlite3_step(statement) }
        return result == SQLITE_DONE
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map(String.init(cString:))
    }

    private func lastError() -> String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
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
