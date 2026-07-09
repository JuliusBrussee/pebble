// LAN multiplayer wire protocol — little-endian binary messages framed by the
// transport as [u32 length][u8 type][payload]. Host-authoritative model: the
// guest streams world deltas and replays its actions on the host through a
// puppet Player. Chunks travel as the existing VCK1 ChunkRecord container;
// one-shot/rich payloads (welcome, entity spawns, item stacks) ride as JSON.
//
// Decode policy (pinned — do not loosen without bumping NET_PROTOCOL_VERSION):
//   - zero-length frame: NetMsg.decode(Data()) throws .underflow (no type byte).
//   - unknown message type: throws .badType(id). Never skipped, never trapped.
//   - short/truncated payload (a field reads past the end): throws .underflow.
//     This includes a length-prefixed blob/string whose declared length runs
//     past the buffer.
//   - trailing bytes (payload longer than the message's fields consume):
//     throws .trailingBytes(n). A message is either fully consumed or rejected.
//   - a frame whose OUTER [u32 length] exceeds NET_MAX_FRAME is a hard
//     disconnect at the transport layer (see FrameCodec in NetTransport.swift),
//     never a truncation to wait out — the sender is misbehaving or corrupt.
// None of the above ever traps (force-unwrap/index-out-of-range): a hostile or
// truncated buffer always surfaces as a thrown NetProtocolError.

import Foundation

public let NET_PROTOCOL_VERSION: UInt16 = 3   // 3: armor + offhand in playerState (visible gear)
public let NET_SERVICE_TYPE = "_pebble._tcp"
/// hard cap on a single framed message (a full chunk record is ~500 KB)
public let NET_MAX_FRAME = 8 << 20

public enum NetProtocolError: Error, Equatable {
    case underflow            // fewer bytes remain than the field needs
    case badString             // string bytes are not valid UTF-8
    case badType(UInt8)        // unknown message type byte
    case trailingBytes(Int)    // n extra bytes after a fully-decoded message
    case blobOversize(Int)     // a length-prefixed blob claims more than NET_MAX_FRAME bytes
}

// =============================================================================
// binary reader/writer
// =============================================================================
public struct PacketWriter {
    public var data = Data()
    public init() {}

    public mutating func u8(_ v: UInt8) { data.append(v) }
    public mutating func bool(_ v: Bool) { data.append(v ? 1 : 0) }
    public mutating func u16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
    public mutating func i32(_ v: Int32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
    public mutating func u32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
    public mutating func i64(_ v: Int64) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func f64(_ v: Double) { var le = v.bitPattern.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
    public mutating func str(_ v: String) {
        let utf8 = Data(v.utf8)
        u16(UInt16(min(utf8.count, 0xFFFF)))
        data.append(utf8.prefix(0xFFFF))
    }
    public mutating func blob(_ v: Data) {
        u32(UInt32(v.count))
        data.append(v)
    }
}

public struct PacketReader {
    public let data: Data
    public var off: Int
    public init(_ data: Data, at: Int = 0) {
        self.data = data
        off = at
    }

    /// kept for source compatibility — use `NetProtocolError` directly in new code
    public typealias Err = NetProtocolError

    private mutating func take(_ n: Int) throws -> Data {
        guard n >= 0, off + n <= data.count else { throw NetProtocolError.underflow }
        // subdata (copy) — the source Data may be a slice of a network buffer,
        // possibly with a non-zero startIndex, so every offset is relative to it
        let out = data.subdata(in: (data.startIndex + off)..<(data.startIndex + off + n))
        off += n
        return out
    }
    public mutating func u8() throws -> UInt8 {
        let b = try take(1)
        return b[b.startIndex]
    }
    public mutating func bool() throws -> Bool { try u8() != 0 }
    public mutating func u16() throws -> UInt16 { UInt16(littleEndian: try take(2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }) }
    public mutating func i32() throws -> Int32 { Int32(littleEndian: try take(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }) }
    public mutating func u32() throws -> UInt32 { UInt32(littleEndian: try take(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) }
    public mutating func i64() throws -> Int64 { Int64(littleEndian: try take(8).withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }) }
    public mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    public mutating func f64() throws -> Double { Double(bitPattern: UInt64(littleEndian: try take(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })) }
    public mutating func str() throws -> String {
        let n = Int(try u16())
        guard let s = String(data: try take(n), encoding: .utf8) else { throw NetProtocolError.badString }
        return s
    }
    public mutating func blob() throws -> Data {
        let n = Int(try u32())
        guard n <= NET_MAX_FRAME else { throw NetProtocolError.blobOversize(n) }
        return try take(n)
    }
}

// =============================================================================
// shared sub-payloads
// =============================================================================
/// a player's own state, ~20×/s. flags: 1 onGround, 2 sneaking, 4 sprinting,
/// 8 usingItem, 16 swing (one-shot arm swing), 32 dead, 64 elytra
public struct NetPlayerState: Equatable {
    public var x = 0.0, y = 0.0, z = 0.0
    public var vx: Float = 0, vy: Float = 0, vz: Float = 0
    public var yaw: Float = 0, pitch: Float = 0
    public var flags: UInt8 = 0
    public var dim: UInt8 = 0
    public var heldId: Int32 = -1
    public var heldMeta: Int32 = 0
    /// worn gear, purely visual: helmet/chest/legs/boots item ids (-1 = none)
    public var armorIds: [Int32] = [-1, -1, -1, -1]
    public var offhandId: Int32 = -1
    public var health: Float = 20

    public init() {}
    func write(_ w: inout PacketWriter) {
        w.f64(x); w.f64(y); w.f64(z)
        w.f32(vx); w.f32(vy); w.f32(vz)
        w.f32(yaw); w.f32(pitch)
        w.u8(flags); w.u8(dim)
        w.i32(heldId); w.i32(heldMeta)
        for i in 0..<4 { w.i32(i < armorIds.count ? armorIds[i] : -1) }
        w.i32(offhandId)
        w.f32(health)
    }
    static func read(_ r: inout PacketReader) throws -> NetPlayerState {
        var s = NetPlayerState()
        s.x = try r.f64(); s.y = try r.f64(); s.z = try r.f64()
        s.vx = try r.f32(); s.vy = try r.f32(); s.vz = try r.f32()
        s.yaw = try r.f32(); s.pitch = try r.f32()
        s.flags = try r.u8(); s.dim = try r.u8()
        s.heldId = try r.i32(); s.heldMeta = try r.i32()
        s.armorIds = [try r.i32(), try r.i32(), try r.i32(), try r.i32()]
        s.offhandId = try r.i32()
        s.health = try r.f32()
        return s
    }
}

/// one replicated entity, batched. flags: 1 onGround, 2 aiming, 4 grazing,
/// 8 sitting, 16 baby, 32 hurt-pulse, 64 attack-pulse, 128 airborne
public struct NetEntityState: Equatable {
    public var eid: Int32 = 0
    public var x = 0.0, y = 0.0, z = 0.0
    public var yaw: Float = 0, pitch: Float = 0, headYaw: Float = 0
    public var flags: UInt8 = 0
    /// generic per-type extra (shulker peek 0..100, slime size, item age…)
    public var aux: UInt8 = 0

    public init() {}
    func write(_ w: inout PacketWriter) {
        w.i32(eid)
        w.f64(x); w.f64(y); w.f64(z)
        w.f32(yaw); w.f32(pitch); w.f32(headYaw)
        w.u8(flags); w.u8(aux)
    }
    static func read(_ r: inout PacketReader) throws -> NetEntityState {
        var s = NetEntityState()
        s.eid = try r.i32()
        s.x = try r.f64(); s.y = try r.f64(); s.z = try r.f64()
        s.yaw = try r.f32(); s.pitch = try r.f32(); s.headYaw = try r.f32()
        s.flags = try r.u8(); s.aux = try r.u8()
        return s
    }
}

/// the one-shot join payload (JSON — happens once, flexibility wins)
public struct NetWelcome: Codable {
    public var hostVersion = PEBBLE_VERSION
    public var worldName = ""
    public var seed: Int32 = 0
    public var gameMode = 0
    public var difficulty = 2
    public var spawnX = 0, spawnY = 80, spawnZ = 0
    public var gameRules: [String: Double] = [:]
    public var dims: [String: DimState] = [:]
    public var dragonKilled = false
    /// entity id of the guest's puppet on the host (other clients see this id)
    public var yourEid = 0
    /// the host's permanent identity + display name (empty on dedicated servers)
    public var hostId = ""
    public var hostName = ""
    /// true when no host player exists (standalone pebserver world)
    public var dedicated = false
    public var dim = 0
    /// spawn position for this guest (their saved spot or world spawn)
    public var x = 0.0, y = 80.0, z = 0.0
    /// players already online: [eid: name]
    public var players: [String: String] = [:]
    /// chunk keys ("dim:cx:cz") the host has edits for — anything else regenerates
    public var modifiedKeys: [String] = []
    /// the guest's saved player data on this host (returning player), JSON blob
    public var playerData: Data? = nil

    public init() {}
}

/// periodic clock/weather sync (JSON, 1×/s)
public struct NetTimeSync: Codable {
    public var dims: [String: DimState] = [:]
    public init() {}
}

// =============================================================================
// messages
// =============================================================================
public enum NetMsg {
    // client → server
    case hello(name: String, pid: String, version: String, proto: UInt16, skin: Data)
    case chunkReq(dim: UInt8, cx: Int32, cz: Int32)
    case playerState(NetPlayerState)
    case blockBreak(dim: UInt8, x: Int32, y: Int32, z: Int32, held: Data)
    case useBlock(dim: UInt8, x: Int32, y: Int32, z: Int32, face: UInt8,
                  px: Float, py: Float, pz: Float, sneaking: Bool, held: Data)
    case useItem(held: Data)
    case stopUsing(useTicks: Int32, held: Data)
    case useEntity(eid: Int32)
    case attack(eid: Int32, held: Data)
    case dropItem(stack: Data)
    case chat(text: String)
    case playerSave(json: Data)
    case goodbye

    // server → client
    case welcome(json: Data)
    case chunkData(dim: UInt8, cx: Int32, cz: Int32, record: Data)   // empty record = generate locally
    case setBlock(dim: UInt8, x: Int32, y: Int32, z: Int32, cell: Int32)
    case entitySpawn(eid: Int32, dim: UInt8, json: Data)
    case entityBatch(dim: UInt8, states: [NetEntityState])
    case entityRemove(eids: [Int32])
    case entityEvent(eid: Int32, kind: UInt8)   // 1 hurt, 2 death, 3 attack-swing
    case playerJoin(eid: Int32, name: String, pid: String, skin: Data)
    case playerLeave(eid: Int32, name: String)
    case playerStateS(eid: Int32, state: NetPlayerState)
    case giveItem(stack: Data)
    case giveXP(amount: Int32)
    case damage(amount: Float, source: String)
    case timeSync(json: Data)
    case sound(name: String, dim: UInt8, x: Float, y: Float, z: Float, vol: Float, pitch: Float)
    case particles(kind: String, dim: UInt8, x: Float, y: Float, z: Float, count: Int32, spread: Float, cell: Int32)
    case chatS(text: String)
    case beSync(dim: UInt8, x: Int32, y: Int32, z: Int32, json: Data)
    case disconnect(reason: String)

    // wire type ids — appended only, never renumbered
    var typeId: UInt8 {
        switch self {
        case .hello: return 1
        case .chunkReq: return 2
        case .playerState: return 3
        case .blockBreak: return 4
        case .useBlock: return 5
        case .useItem: return 6
        case .stopUsing: return 7
        case .useEntity: return 8
        case .attack: return 9
        case .dropItem: return 10
        case .chat: return 11
        case .playerSave: return 12
        case .goodbye: return 13
        case .welcome: return 30
        case .chunkData: return 31
        case .setBlock: return 32
        case .entitySpawn: return 33
        case .entityBatch: return 34
        case .entityRemove: return 35
        case .entityEvent: return 36
        case .playerJoin: return 37
        case .playerLeave: return 38
        case .playerStateS: return 39
        case .giveItem: return 40
        case .giveXP: return 41
        case .damage: return 42
        case .timeSync: return 43
        case .sound: return 44
        case .particles: return 45
        case .chatS: return 46
        case .beSync: return 47
        case .disconnect: return 48
        }
    }

    public func encode() -> Data {
        var w = PacketWriter()
        w.u8(typeId)
        switch self {
        case let .hello(name, pid, version, proto, skin):
            w.str(name); w.str(pid); w.str(version); w.u16(proto); w.blob(skin)
        case let .chunkReq(dim, cx, cz):
            w.u8(dim); w.i32(cx); w.i32(cz)
        case let .playerState(s):
            s.write(&w)
        case let .blockBreak(dim, x, y, z, held):
            w.u8(dim); w.i32(x); w.i32(y); w.i32(z); w.blob(held)
        case let .useBlock(dim, x, y, z, face, px, py, pz, sneaking, held):
            w.u8(dim); w.i32(x); w.i32(y); w.i32(z); w.u8(face)
            w.f32(px); w.f32(py); w.f32(pz); w.bool(sneaking); w.blob(held)
        case let .useItem(held):
            w.blob(held)
        case let .stopUsing(useTicks, held):
            w.i32(useTicks); w.blob(held)
        case let .useEntity(eid):
            w.i32(eid)
        case let .attack(eid, held):
            w.i32(eid); w.blob(held)
        case let .dropItem(stack):
            w.blob(stack)
        case let .chat(text):
            w.str(text)
        case let .playerSave(json):
            w.blob(json)
        case .goodbye:
            break
        case let .welcome(json):
            w.blob(json)
        case let .chunkData(dim, cx, cz, record):
            w.u8(dim); w.i32(cx); w.i32(cz); w.blob(record)
        case let .setBlock(dim, x, y, z, cell):
            w.u8(dim); w.i32(x); w.i32(y); w.i32(z); w.i32(cell)
        case let .entitySpawn(eid, dim, json):
            w.i32(eid); w.u8(dim); w.blob(json)
        case let .entityBatch(dim, states):
            w.u8(dim); w.u16(UInt16(min(states.count, 0xFFFF)))
            for s in states.prefix(0xFFFF) { s.write(&w) }
        case let .entityRemove(eids):
            w.u16(UInt16(min(eids.count, 0xFFFF)))
            for e in eids.prefix(0xFFFF) { w.i32(e) }
        case let .entityEvent(eid, kind):
            w.i32(eid); w.u8(kind)
        case let .playerJoin(eid, name, pid, skin):
            w.i32(eid); w.str(name); w.str(pid); w.blob(skin)
        case let .playerLeave(eid, name):
            w.i32(eid); w.str(name)
        case let .playerStateS(eid, state):
            w.i32(eid); state.write(&w)
        case let .giveItem(stack):
            w.blob(stack)
        case let .giveXP(amount):
            w.i32(amount)
        case let .damage(amount, source):
            w.f32(amount); w.str(source)
        case let .timeSync(json):
            w.blob(json)
        case let .sound(name, dim, x, y, z, vol, pitch):
            w.str(name); w.u8(dim); w.f32(x); w.f32(y); w.f32(z); w.f32(vol); w.f32(pitch)
        case let .particles(kind, dim, x, y, z, count, spread, cell):
            w.str(kind); w.u8(dim); w.f32(x); w.f32(y); w.f32(z); w.i32(count); w.f32(spread); w.i32(cell)
        case let .chatS(text):
            w.str(text)
        case let .beSync(dim, x, y, z, json):
            w.u8(dim); w.i32(x); w.i32(y); w.i32(z); w.blob(json)
        case let .disconnect(reason):
            w.str(reason)
        }
        return w.data
    }

    public static func decode(_ data: Data) throws -> NetMsg {
        var r = PacketReader(data)
        let type = try r.u8()
        let msg: NetMsg
        switch type {
        case 1: msg = .hello(name: try r.str(), pid: try r.str(), version: try r.str(),
                             proto: try r.u16(), skin: try r.blob())
        case 2: msg = .chunkReq(dim: try r.u8(), cx: try r.i32(), cz: try r.i32())
        case 3: msg = .playerState(try NetPlayerState.read(&r))
        case 4: msg = .blockBreak(dim: try r.u8(), x: try r.i32(), y: try r.i32(), z: try r.i32(), held: try r.blob())
        case 5: msg = .useBlock(dim: try r.u8(), x: try r.i32(), y: try r.i32(), z: try r.i32(),
                                face: try r.u8(), px: try r.f32(), py: try r.f32(), pz: try r.f32(),
                                sneaking: try r.bool(), held: try r.blob())
        case 6: msg = .useItem(held: try r.blob())
        case 7: msg = .stopUsing(useTicks: try r.i32(), held: try r.blob())
        case 8: msg = .useEntity(eid: try r.i32())
        case 9: msg = .attack(eid: try r.i32(), held: try r.blob())
        case 10: msg = .dropItem(stack: try r.blob())
        case 11: msg = .chat(text: try r.str())
        case 12: msg = .playerSave(json: try r.blob())
        case 13: msg = .goodbye
        case 30: msg = .welcome(json: try r.blob())
        case 31: msg = .chunkData(dim: try r.u8(), cx: try r.i32(), cz: try r.i32(), record: try r.blob())
        case 32: msg = .setBlock(dim: try r.u8(), x: try r.i32(), y: try r.i32(), z: try r.i32(), cell: try r.i32())
        case 33: msg = .entitySpawn(eid: try r.i32(), dim: try r.u8(), json: try r.blob())
        case 34:
            let dim = try r.u8()
            let n = Int(try r.u16())
            var states: [NetEntityState] = []
            states.reserveCapacity(n)
            for _ in 0..<n { states.append(try NetEntityState.read(&r)) }
            msg = .entityBatch(dim: dim, states: states)
        case 35:
            let n = Int(try r.u16())
            var eids: [Int32] = []
            eids.reserveCapacity(n)
            for _ in 0..<n { eids.append(try r.i32()) }
            msg = .entityRemove(eids: eids)
        case 36: msg = .entityEvent(eid: try r.i32(), kind: try r.u8())
        case 37: msg = .playerJoin(eid: try r.i32(), name: try r.str(), pid: try r.str(), skin: try r.blob())
        case 38: msg = .playerLeave(eid: try r.i32(), name: try r.str())
        case 39: msg = .playerStateS(eid: try r.i32(), state: try NetPlayerState.read(&r))
        case 40: msg = .giveItem(stack: try r.blob())
        case 41: msg = .giveXP(amount: try r.i32())
        case 42: msg = .damage(amount: try r.f32(), source: try r.str())
        case 43: msg = .timeSync(json: try r.blob())
        case 44: msg = .sound(name: try r.str(), dim: try r.u8(), x: try r.f32(), y: try r.f32(),
                              z: try r.f32(), vol: try r.f32(), pitch: try r.f32())
        case 45: msg = .particles(kind: try r.str(), dim: try r.u8(), x: try r.f32(), y: try r.f32(),
                                  z: try r.f32(), count: try r.i32(), spread: try r.f32(), cell: try r.i32())
        case 46: msg = .chatS(text: try r.str())
        case 47: msg = .beSync(dim: try r.u8(), x: try r.i32(), y: try r.i32(), z: try r.i32(), json: try r.blob())
        case 48: msg = .disconnect(reason: try r.str())
        default: throw NetProtocolError.badType(type)
        }
        guard r.off == data.count else { throw NetProtocolError.trailingBytes(data.count - r.off) }
        return msg
    }
}

// =============================================================================
// ChunkRecord ↔ wire bytes — reuse the exact VCK1 container the save DB uses
// =============================================================================
/// encode a live chunk (blocks + biomes + block entities, NO entities — the
/// host streams entities live) into the VCK1 container for the wire
public func encodeChunkForWire(_ c: Chunk) -> Data {
    var data = Data("VCK1".utf8)
    data.append(1)
    func putU32(_ v: Int) {
        var le = UInt32(v).littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    putU32(c.blocks.count)
    // explicit little-endian, element by element — no withMemoryRebound (that
    // reinterprets native byte order, which only happens to match LE on the
    // little-endian hosts we build for; this stays correct if that changes)
    data.reserveCapacity(data.count + c.blocks.count * 2)
    for v in c.blocks {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    putU32(c.biomes.count)
    data.append(contentsOf: c.biomes)
    var tail: [String: Any] = ["entities": [[String: Any]]()]
    let bes = c.blockEntities.values.sorted { ($0.y, $0.x, $0.z) < ($1.y, $1.x, $1.z) }
    if !bes.isEmpty, let enc = try? JSONEncoder().encode(bes),
       let obj = try? JSONSerialization.jsonObject(with: enc) {
        tail["blockEntities"] = obj
    }
    // sortedKeys: the JSON tail is protocol-visible (rides the wire in every
    // chunkData message) — pin its byte order regardless of Dictionary's
    // internal (hash-seed-dependent) iteration order
    let json = (try? JSONSerialization.data(withJSONObject: tail, options: [.sortedKeys])) ?? Data("{}".utf8)
    putU32(json.count)
    data.append(json)
    return data
}

/// decode wire VCK1 bytes into a ChunkRecord (mirrors SaveDB.decodeChunk)
public func decodeWireChunk(_ data: Data, dim: Int, cx: Int, cz: Int) -> ChunkRecord? {
    var rec = ChunkRecord(key: "net:\(dim):\(cx),\(cz)", worldId: "net", dim: dim, cx: cx, cz: cz)
    var off = 0
    func readU32() -> Int? {
        guard off + 4 <= data.count else { return nil }
        let v = data.subdata(in: (data.startIndex + off)..<(data.startIndex + off + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        off += 4
        return Int(UInt32(littleEndian: v))
    }
    guard data.count >= 5, data.prefix(4) == Data("VCK1".utf8) else { return nil }
    off = 4
    let flags = data[data.startIndex + 4]
    off += 1
    if flags & 1 != 0 {
        guard let nBlocks = readU32(), nBlocks >= 0, off + nBlocks * 2 <= data.count else { return nil }
        var blocks = [UInt16](repeating: 0, count: nBlocks)
        // explicit little-endian, unaligned-safe — mirrors PacketReader.u16()
        let blockBytes = data.subdata(in: (data.startIndex + off)..<(data.startIndex + off + nBlocks * 2))
        blockBytes.withUnsafeBytes { raw in
            for i in 0..<nBlocks {
                blocks[i] = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
            }
        }
        off += nBlocks * 2
        let maxId = UInt16(blockDefs.count)
        for i in 0..<blocks.count where (blocks[i] >> 4) >= maxId { blocks[i] = 0 }
        rec.blocks = blocks
        guard let nBiomes = readU32(), off + nBiomes <= data.count else { return nil }
        rec.biomes = [UInt8](data.subdata(in: (data.startIndex + off)..<(data.startIndex + off + nBiomes)))
        off += nBiomes
    }
    guard let jsonLen = readU32(), off + jsonLen <= data.count,
          let tail = try? JSONSerialization.jsonObject(with: data.subdata(in: (data.startIndex + off)..<(data.startIndex + off + jsonLen))) as? [String: Any]
    else { return nil }
    rec.entities = []   // entities never ride wire chunks — the host streams them
    if let rawBE = tail["blockEntities"],
       let bytes = try? JSONSerialization.data(withJSONObject: rawBE),
       let bes = try? JSONDecoder().decode([BlockEntityData].self, from: bytes) {
        rec.blockEntities = bes
    }
    return rec
}
