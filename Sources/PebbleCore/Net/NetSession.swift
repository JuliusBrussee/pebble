// LAN multiplayer sessions. The HOST runs the real world; every guest is a
// puppet Player entity on the host, driven by playerState messages, and guest
// actions (break/place/use/attack) replay on the host through the normal
// Interact/Combat paths so drops, redstone and mob AI need no special cases.
// The GUEST regenerates unmodified terrain from the seed, fetches modified
// chunks from the host, runs only its own player physics, and renders shadow
// entities interpolated toward the host's states.

import Foundation
import Network

@inline(__always) private func stackJSON(_ s: ItemStack?) -> Data {
    s.flatMap { try? JSONEncoder().encode($0) } ?? Data()
}
@inline(__always) private func stackFrom(_ d: Data) -> ItemStack? {
    d.isEmpty ? nil : try? JSONDecoder().decode(ItemStack.self, from: d)
}
@inline(__always) private func netChunkKeyStr(_ dim: Int, _ cx: Int, _ cz: Int) -> String {
    "\(dim):\(cx):\(cz)"
}

/// build the on-wire state for any player entity
func netStateOf(_ p: Player, dim: Dim, swing: Bool) -> NetPlayerState {
    var s = NetPlayerState()
    s.x = p.x; s.y = p.y; s.z = p.z
    s.vx = Float(p.vx); s.vy = Float(p.vy); s.vz = Float(p.vz)
    s.yaw = Float(p.yaw); s.pitch = Float(p.pitch)
    var f: UInt8 = 0
    if p.onGround { f |= 1 }
    if p.sneaking { f |= 2 }
    if p.sprinting { f |= 4 }
    if p.usingItem { f |= 8 }
    if swing { f |= 16 }
    if p.dead || p.deathTime > 0 { f |= 32 }
    if p.elytraFlying { f |= 64 }
    s.flags = f
    s.dim = UInt8(dim.rawValue)
    s.heldId = Int32(p.mainHand?.id ?? -1)
    s.heldMeta = Int32(p.mainHand?.damage ?? 0)
    s.armorIds = (0..<4).map { Int32(p.armor.indices.contains($0) ? (p.armor[$0]?.id ?? -1) : -1) }
    s.offhandId = Int32(p.offHand?.id ?? -1)
    s.health = Float(p.health)
    return s
}

/// mirror the visual gear from a wire state onto a puppet/shadow player
func applyGearMirror(_ p: Player, _ s: NetPlayerState) {
    for i in 0..<min(4, s.armorIds.count) where p.armor.indices.contains(i) {
        let id = Int(s.armorIds[i])
        if id >= 0 && id < itemDefs.count {
            if p.armor[i]?.id != id { p.armor[i] = ItemStack(id, 1) }
        } else {
            p.armor[i] = nil
        }
    }
    let off = Int(s.offhandId)
    if off >= 0 && off < itemDefs.count {
        if p.offHand?.id != off { p.offHand = ItemStack(off, 1) }
    } else {
        p.offHand = nil
    }
}

// =============================================================================
// HOST
// =============================================================================
public final class NetHostSession {
    final class Guest {
        let conn: NetConnection
        var name = ""
        var pid = ""       // permanent identity from their hello
        var skin = Data()
        var puppet: Player?
        var ready = false               // hello done, welcome sent
        var knownEntities = Set<Int>()  // eids replicated to this guest
        var knownDim = -1
        var lastHealth = 20.0
        var swingPulse = false
        init(_ conn: NetConnection) { self.conn = conn }
    }

    unowned let game: GameCore
    let serviceName: String
    private let listener = NetListener()
    private var guests: [Guest] = []
    private var stopped = false
    /// no host player — a standalone pebserver world
    public let dedicated: Bool
    private let fixedPort: UInt16?
    private let worldName: String
    /// console sink for dedicated servers (joins/leaves/chat)
    public var onLog: ((String) -> Void)?

    public var hasGuests: Bool { guests.contains { $0.ready } }
    public var guestCount: Int { guests.lazy.filter { $0.ready }.count }
    public var guestNames: [String] { guests.filter { $0.ready }.map { $0.name } }
    /// TCP port once the listener is ready (0 before) — tests dial it directly
    public var port: UInt16 { listener.port }
    public var hostName: String

    public init(game: GameCore, hostName: String, worldName: String,
                dedicated: Bool = false, fixedPort: UInt16? = nil) {
        self.game = game
        self.hostName = hostName
        self.worldName = worldName
        self.dedicated = dedicated
        self.fixedPort = fixedPort
        serviceName = dedicated ? worldName : "\(hostName) — \(worldName)"
    }

    /// chat/console line: the host player's chat + the server console
    private func log(_ line: String) {
        game.host?.pushChat(line)
        onLog?(line)
    }

    public func start() throws {
        listener.onConnection = { [weak self] conn in
            guard let self, !self.stopped else {
                conn.close()
                return
            }
            let g = Guest(conn)
            self.guests.append(g)
            conn.onMessage = { [weak self, weak g] msg in
                guard let self, let g else { return }
                self.handle(g, msg)
            }
            conn.onClosed = { [weak self, weak g] _ in
                guard let self, let g else { return }
                self.dropGuest(g, announce: true)
            }
        }
        try listener.start(serviceName: serviceName, fixedPort: fixedPort, txt: [
            "pid": dedicated ? "" : (game.settings.playerId ?? ""),
            "name": hostName,
            "world": worldName,
            "ver": PEBBLE_VERSION,
            "srv": dedicated ? "1" : "0",
        ])
        installWorldHooks()
    }

    public func shutdown() {
        if stopped { return }
        stopped = true
        for g in guests {
            g.conn.send(.disconnect(reason: "host closed the world"))
            g.conn.close()
            removePuppet(g)
        }
        guests.removeAll()
        listener.stop()
    }

    // ---- world hooks: broadcast block changes / sounds / particles ----------
    private func installWorldHooks() {
        for (d, w) in game.worlds {
            let dim = UInt8(d.rawValue)
            w.hooks.onBlockChanged = { [weak self] x, y, z, _, cell in
                self?.broadcast(.setBlock(dim: dim, x: Int32(x), y: Int32(y), z: Int32(z), cell: Int32(cell)))
            }
            let oldSound = w.hooks.playSound
            w.hooks.playSound = { [weak self] name, x, y, z, vol, pitch in
                oldSound(name, x, y, z, vol, pitch)
                self?.broadcast(.sound(name: name, dim: dim, x: Float(x), y: Float(y), z: Float(z),
                                       vol: Float(vol), pitch: Float(pitch)))
            }
            let oldParticles = w.hooks.addParticles
            w.hooks.addParticles = { [weak self] type, x, y, z, count, spread, cell in
                oldParticles(type, x, y, z, count, spread, cell)
                self?.broadcast(.particles(kind: type, dim: dim, x: Float(x), y: Float(y), z: Float(z),
                                           count: Int32(count), spread: Float(spread), cell: Int32(cell)))
            }
        }
    }

    private func broadcast(_ msg: NetMsg, except: Guest? = nil) {
        if stopped { return }
        if case .setBlock = msg, ProcessInfo.processInfo.environment["PEBBLE_NETDEBUG"] != nil {
            print("[netdbg] session \(ObjectIdentifier(self)) broadcast setBlock → \(guests.filter { $0.ready }.count) ready guest(s), dedicated=\(dedicated)")
        }
        for g in guests where g.ready && g !== except {
            g.conn.send(msg)
        }
    }

    public func broadcastChat(_ line: String) {
        broadcast(.chatS(text: line))
    }

    // ---- join / leave ---------------------------------------------------------
    private func handle(_ g: Guest, _ msg: NetMsg) {
        if stopped { return }
        switch msg {
        case let .hello(name, pid, version, proto, skin):
            handleHello(g, name, pid, version, proto, skin)
        case let .chunkReq(dim, cx, cz):
            guard g.ready else { return }
            g.conn.send(.chunkData(dim: dim, cx: cx, cz: cz,
                                   record: game.netChunkPayload(Int(dim), Int(cx), Int(cz))))
        case let .playerState(s):
            applyPuppetState(g, s)
        case let .blockBreak(dim, x, y, z, held):
            guard let p = puppetIn(g, dim) else { return }
            p.mainHand = stackFrom(held)
            finishBreaking(puppetCtx(g, p), Int(x), Int(y), Int(z))
        case let .useBlock(dim, x, y, z, face, px, py, pz, sneaking, held):
            guard let p = puppetIn(g, dim) else { return }
            p.mainHand = stackFrom(held)
            p.sneaking = sneaking
            let cell = p.world.getBlock(Int(x), Int(y), Int(z))
            let hit = RaycastHit(x: Int(x), y: Int(y), z: Int(z), face: Int(face), cell: cell,
                                 t: 0, px: Double(px), py: Double(py), pz: Double(pz))
            let ctx = puppetCtx(g, p)
            if !useBlock(ctx, hit) {
                _ = useItem(ctx, hit)
            }
        case let .useItem(held):
            guard let p = g.puppet else { return }
            p.mainHand = stackFrom(held)
            _ = useItem(puppetCtx(g, p), puppetCrosshair(p))
        case let .stopUsing(useTicks, held):
            guard let p = g.puppet else { return }
            p.mainHand = stackFrom(held)
            p.usingItem = true
            p.useItemHand = "main"
            p.useItemTicks = Int(useTicks)
            releaseUsingItem(puppetCtx(g, p))
        case let .useEntity(eid):
            guard let p = g.puppet, let target = p.world.entityById[Int(eid)] as? Entity else { return }
            _ = target.interact(p, p.mainHand)
        case let .attack(eid, held):
            guard let p = g.puppet, let target = p.world.entityById[Int(eid)] as? Entity,
                  !target.dead, target.distanceTo(p) < ATTACK_REACH + 3 else { return }
            p.mainHand = stackFrom(held)
            p.attackAnim = 1
            g.swingPulse = true
            if target is LivingEntity || target.type == "end_crystal" {
                playerAttack(p, target)
            } else if target.type == "boat" || target.type == "minecart" {
                _ = target.hurt(2, "player", p)
            }
        case let .dropItem(stack):
            guard let p = g.puppet, let s = stackFrom(stack) else { return }
            let e = spawnItem(p.world, p.x, p.eyeY() - 0.3, p.z, s)
            e.vx = -detSin(p.yaw) * 0.3
            e.vy = 0.1
            e.vz = detCos(p.yaw) * 0.3
            e.pickupDelay = 40
        case let .chat(text):
            let clean = String(text.prefix(256)).replacingOccurrences(of: "\n", with: " ")
            if clean.hasPrefix("/") {
                g.conn.send(.chatS(text: "§cCommands only work for the host (for now)."))
                return
            }
            let line = "<\(g.name)> \(clean)"
            log(line)
            broadcast(.chatS(text: line))
        case let .playerSave(json):
            guard g.ready, json.count < 1 << 20, let rec = game.worldRec,
                  let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return }
            game.db.putPlayer(Self.saveKey(rec.id, pid: g.pid, name: g.name), obj)
        case .goodbye:
            g.conn.close()
            dropGuest(g, announce: true)
        default:
            break
        }
    }

    /// player-data row key: permanent id first, legacy name key as fallback
    static func saveKey(_ worldId: String, pid: String, name: String) -> String {
        pid.isEmpty ? "\(worldId)#\(name)" : "\(worldId)#id:\(pid)"
    }

    private func handleHello(_ g: Guest, _ name: String, _ pid: String, _ version: String, _ proto: UInt16, _ skin: Data) {
        guard !g.ready, game.inWorld, let rec = game.worldRec else {
            g.conn.send(.disconnect(reason: "host is not in a world"))
            g.conn.close()
            return
        }
        guard proto == NET_PROTOCOL_VERSION else {
            g.conn.send(.disconnect(reason: "version mismatch — host runs Pebble \(PEBBLE_VERSION), you run \(version)"))
            g.conn.close()
            return
        }
        // sanitize + dedupe the name (identity is the pid, the name is display)
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        base = String(base.prefix(16)).filter { !$0.isNewline }
        if base.isEmpty { base = "Player" }
        var final = base
        var n = 2
        while (!dedicated && final == hostName)
            || guests.contains(where: { $0.ready && $0.name == final }) {
            final = "\(base)\(n)"
            n += 1
        }
        g.name = final
        g.pid = String(pid.prefix(64))
        g.skin = skin.count <= 1 << 18 ? skin : Data()
        game.socialStore.recordRecent(id: g.pid, name: final, how: "joined you")

        // returning guest? restore their saved spot + inventory (id key first,
        // then the legacy name key from pre-identity versions)
        let savedKey = Self.saveKey(rec.id, pid: g.pid, name: final)
        let saved = game.db.getPlayer(savedKey) ?? game.db.getPlayer("\(rec.id)#\(final)")
        let dim = Dim(rawValue: (saved?["dim"] as? NSNumber)?.intValue ?? 0) ?? .overworld
        let w = game.worlds[dim]!
        let puppet = Player(world: w)
        puppet.setGameMode(rec.gameMode)
        puppet.netPickupSuppressed = true   // the session grants pickups explicitly
        puppet.netPuppet = true             // never dies host-side; the guest decides
        if let pd = saved?["data"] as? [String: Any] {
            puppet.load(pd)
            if !puppet.x.isFinite || !puppet.y.isFinite || !puppet.z.isFinite {
                puppet.setPos(Double(rec.spawnX) + 0.5, Double(rec.spawnY + 1), Double(rec.spawnZ) + 0.5)
            }
        } else {
            puppet.setPos(Double(rec.spawnX) + 0.5, Double(rec.spawnY + 1), Double(rec.spawnZ) + 0.5)
        }
        w.addEntity(puppet)
        g.puppet = puppet
        g.knownDim = dim.rawValue
        g.lastHealth = puppet.health
        g.ready = true

        // welcome
        var wel = NetWelcome()
        wel.worldName = rec.name
        wel.seed = rec.seed
        wel.gameMode = rec.gameMode
        wel.difficulty = rec.difficulty
        wel.spawnX = rec.spawnX; wel.spawnY = rec.spawnY; wel.spawnZ = rec.spawnZ
        wel.gameRules = game.world.gameRules
        wel.dragonKilled = rec.dragonKilled
        for (d, dw) in game.worlds {
            wel.dims["\(d.rawValue)"] = DimState(time: dw.time, dayTime: dw.dayTime, raining: dw.raining,
                                                 thundering: dw.thundering, weatherTimer: dw.weatherTimer)
        }
        wel.yourEid = puppet.id
        wel.dim = dim.rawValue
        wel.x = puppet.x; wel.y = puppet.y; wel.z = puppet.z
        wel.hostId = dedicated ? "" : (game.settings.playerId ?? "")
        wel.hostName = hostName
        wel.dedicated = dedicated
        wel.players = [:]
        if let hp = game.player { wel.players["\(hp.id)"] = hostName }
        for other in guests where other.ready && other !== g {
            if let op = other.puppet { wel.players["\(op.id)"] = other.name }
        }
        wel.modifiedKeys = game.netModifiedKeyList()
        if let pd = saved, let blob = try? JSONSerialization.data(withJSONObject: pd) {
            wel.playerData = blob
        }
        if let json = try? JSONEncoder().encode(wel) {
            g.conn.send(.welcome(json: json))
        }
        // introduce everyone
        if let hp = game.player {
            g.conn.send(.playerJoin(eid: Int32(hp.id), name: hostName,
                                    pid: game.settings.playerId ?? "", skin: Data()))
        }
        for other in guests where other.ready && other !== g {
            if let op = other.puppet {
                g.conn.send(.playerJoin(eid: Int32(op.id), name: other.name, pid: other.pid, skin: other.skin))
            }
        }
        broadcast(.playerJoin(eid: Int32(puppet.id), name: final, pid: g.pid, skin: g.skin), except: g)
        if ProcessInfo.processInfo.environment["PEBBLE_NETDEBUG"] != nil {
            print("[netdbg] session \(ObjectIdentifier(self)) hello from \(final), dedicated=\(dedicated)")
        }
        let joinLine = "§e\(final) joined the game"
        log(joinLine)
        broadcast(.chatS(text: joinLine), except: g)
    }

    private func dropGuest(_ g: Guest, announce: Bool) {
        guard let idx = guests.firstIndex(where: { $0 === g }) else { return }
        guests.remove(at: idx)
        let wasReady = g.ready
        g.ready = false
        removePuppet(g)
        if wasReady && announce {
            let line = "§e\(g.name) left the game"
            log(line)
            broadcast(.chatS(text: line))
            broadcast(.playerLeave(eid: Int32(g.puppet?.id ?? 0), name: g.name))
        }
    }

    private func removePuppet(_ g: Guest) {
        if let p = g.puppet {
            savePuppet(g)
            p.world.removeEntity(p)
            g.puppet = nil
        }
    }

    /// persist the puppet's last-known spot so the guest rejoins where they left
    private func savePuppet(_ g: Guest) {
        guard let p = g.puppet, let rec = game.worldRec, !g.name.isEmpty else { return }
        let key = Self.saveKey(rec.id, pid: g.pid, name: g.name)
        var existing = game.db.getPlayer(key) ?? [:]
        var data = (existing["data"] as? [String: Any]) ?? p.save()
        data["x"] = p.x; data["y"] = p.y; data["z"] = p.z
        data["yaw"] = p.yaw; data["pitch"] = p.pitch
        existing["dim"] = p.world.dim.rawValue
        existing["data"] = data
        game.db.putPlayer(key, existing)
    }

    // ---- puppet plumbing --------------------------------------------------------
    private func puppetIn(_ g: Guest, _ dim: UInt8) -> Player? {
        guard let p = g.puppet, p.world.dim.rawValue == Int(dim) else { return nil }
        return p
    }

    private func puppetCtx(_ g: Guest, _ p: Player) -> InteractCtx {
        InteractCtx(
            world: p.world,
            player: p,
            openScreen: { [weak g] kind, data in
                // containers open on the guest's screen, not the host's —
                // send the backing block entity so the guest sees live contents
                guard let g, let data else { return }
                if let be = data.be, let enc = try? JSONEncoder().encode(be) {
                    g.conn.send(.beSync(dim: UInt8(p.world.dim.rawValue),
                                        x: Int32(be.x), y: Int32(be.y), z: Int32(be.z), json: enc))
                }
                _ = kind
            },
            advance: { _ in })
    }

    private func puppetCrosshair(_ p: Player) -> RaycastHit? {
        let dx = -detSin(p.yaw) * detCos(p.pitch)
        let dy = -detSin(p.pitch)
        let dz = detCos(p.yaw) * detCos(p.pitch)
        return p.world.raycast(p.x, p.eyeY(), p.z, dx, dy, dz,
                               p.gameMode == GameMode.creative ? REACH_CREATIVE : REACH_SURVIVAL)
    }

    private func applyPuppetState(_ g: Guest, _ s: NetPlayerState) {
        guard let p = g.puppet else { return }
        // dimension move
        if Int(s.dim) != p.world.dim.rawValue, let dest = Dim(rawValue: Int(s.dim)),
           let dw = game.worlds[dest] {
            p.world.removeEntity(p)
            p.world = dw
            dw.addEntity(p)
            g.knownDim = dest.rawValue
            // replicated entities are per-dim — reset and let afterTick respawn them
            if !g.knownEntities.isEmpty {
                g.conn.send(.entityRemove(eids: g.knownEntities.map { Int32($0) }))
                g.knownEntities.removeAll()
            }
        }
        p.prevX = p.x; p.prevY = p.y; p.prevZ = p.z
        p.prevYaw = p.yaw; p.prevPitch = p.pitch
        p.x = s.x; p.y = s.y; p.z = s.z
        p.vx = Double(s.vx); p.vy = Double(s.vy); p.vz = Double(s.vz)
        p.yaw = Double(s.yaw); p.pitch = Double(s.pitch)
        p.headYaw = Double(s.yaw)
        p.onGround = s.flags & 1 != 0
        p.sneaking = s.flags & 2 != 0
        p.sprinting = s.flags & 4 != 0
        p.usingItem = s.flags & 8 != 0
        if s.flags & 16 != 0 {
            p.attackAnim = 1
            g.swingPulse = true
        }
        p.elytraFlying = s.flags & 64 != 0
        p.health = Double(min(s.health, Float(p.maxHealth)))
        p.dead = false   // guests handle their own death/respawn
        if s.heldId >= 0 && s.heldId < Int32(itemDefs.count) {
            if p.mainHand?.id != Int(s.heldId) || p.mainHand?.damage != Int(s.heldMeta) {
                p.mainHand = ItemStack(Int(s.heldId), 1, damage: Int(s.heldMeta))
            }
        } else {
            p.mainHand = nil
        }
        applyGearMirror(p, s)
        if s.flags & 32 != 0 {
            // dead guests shouldn't be mob targets or take more hits
            p.invulnTicks = 40
        }
    }

    // ---- per-tick host work ------------------------------------------------------
    public func afterTick() {
        if stopped || guests.isEmpty { return }
        let time = game.world.time

        for g in guests where g.ready {
            guard let p = g.puppet else { continue }
            let w = p.world

            // keep the world alive around the puppet
            if time % 20 == 0 {
                let pcx = floorDiv(ifloor(p.x), 16), pcz = floorDiv(ifloor(p.z), 16)
                for dz in -2...2 {
                    for dx in -2...2 {
                        game.netEnsureChunk(w, pcx + dx, pcz + dz)
                    }
                }
            }

            // puppet cosmetics (position comes from the guest; anims are derived)
            let ddx = p.x - p.prevX, ddz = p.z - p.prevZ
            let speed = (ddx * ddx + ddz * ddz).squareRoot()
            p.limbAmp += (min(1, speed * 2.5) - p.limbAmp) * 0.4
            p.limbSwing += p.limbAmp * 1.2
            if p.attackAnim > 0 { p.attackAnim = max(0, p.attackAnim - 0.125) }
            if p.hurtTime > 0 { p.hurtTime -= 1 }
            if p.invulnTicks > 0 { p.invulnTicks -= 1 }

            // host-authoritative damage: whatever hurt the puppet this tick
            // flows to the guest as a final (post-armor) amount
            if p.health < g.lastHealth - 0.001 {
                let src = p.lastHurtSource ?? "mob"
                g.conn.send(.damage(amount: Float(g.lastHealth - p.health), source: src))
            }
            g.lastHealth = p.health

            // item / xp pickup for the puppet — grants go over the wire
            if time % 2 == 0 && p.health > 0 {
                for e in w.getEntitiesNear(p.x, p.y + 0.5, p.z, 1.6) {
                    if let item = e as? ItemEntity, item.pickupDelay <= 0, !item.dead {
                        g.conn.send(.giveItem(stack: stackJSON(item.stack)))
                        w.hooks.playSound("entity.item.pickup", p.x, p.y, p.z, 0.3, 1.4)
                        item.remove()
                        w.removeEntity(item)
                    } else if let orb = e as? XPOrb, !orb.dead {
                        g.conn.send(.giveXP(amount: Int32(orb.amount)))
                        w.hooks.playSound("entity.experience_orb.pickup", p.x, p.y, p.z, 0.4, 1.0)
                        orb.remove()
                        w.removeEntity(orb)
                    }
                }
            }

            // entity replication (10 Hz)
            if time % 2 == 0 {
                replicateEntities(g, p, w)
            }

            // other players (20 Hz) — dedicated servers have no host player
            if let hp = game.player {
                g.conn.send(.playerStateS(eid: Int32(hp.id),
                                          state: netStateOf(hp, dim: game.dim, swing: game.netConsumeHostSwing())))
            }
            for other in guests where other.ready && other !== g {
                guard let op = other.puppet else { continue }
                var st = netStateOf(op, dim: op.world.dim, swing: other.swingPulse)
                st.health = Float(op.health)
                g.conn.send(.playerStateS(eid: Int32(op.id), state: st))
            }
        }
        for g in guests { g.swingPulse = false }

        // clock + weather, 1 Hz
        if time % 20 == 0 {
            var sync = NetTimeSync()
            for (d, dw) in game.worlds {
                sync.dims["\(d.rawValue)"] = DimState(time: dw.time, dayTime: dw.dayTime, raining: dw.raining,
                                                      thundering: dw.thundering, weatherTimer: dw.weatherTimer)
            }
            if let json = try? JSONEncoder().encode(sync) {
                broadcast(.timeSync(json: json))
            }
        }

        // periodic guest-position save (so a host crash loses little)
        if time % 1200 == 0 {
            for g in guests where g.ready { savePuppet(g) }
        }
    }

    private func replicateEntities(_ g: Guest, _ puppet: Player, _ w: World) {
        let dim = UInt8(w.dim.rawValue)
        let R = 96.0
        var states: [NetEntityState] = []
        var seen = Set<Int>()
        for e in w.entities {
            guard let ent = e as? Entity, !ent.isPlayer, !ent.dead else { continue }
            let dx = ent.x - puppet.x, dz = ent.z - puppet.z
            if dx * dx + dz * dz > R * R { continue }
            seen.insert(ent.id)
            if !g.knownEntities.contains(ent.id) {
                g.knownEntities.insert(ent.id)
                var d = ent.save()
                d["eid"] = ent.id
                if let json = try? JSONSerialization.data(withJSONObject: d) {
                    g.conn.send(.entitySpawn(eid: Int32(ent.id), dim: dim, json: json))
                }
            }
            var s = NetEntityState()
            s.eid = Int32(ent.id)
            s.x = ent.x; s.y = ent.y; s.z = ent.z
            s.yaw = Float(ent.yaw); s.pitch = Float(ent.pitch)
            let liv = ent as? LivingEntity
            s.headYaw = Float(liv?.headYaw ?? ent.yaw)
            var f: UInt8 = 0
            if ent.onGround { f |= 1 }
            if (ent as? Mob)?.target != nil { f |= 2 }
            if ent.data.grazing ?? false { f |= 4 }
            if (ent as? Mob)?.sitting ?? false { f |= 8 }
            if ent.data.baby ?? false { f |= 16 }
            if let liv, liv.hurtTime >= 9 { f |= 32 }
            if let liv, liv.attackAnim >= 0.95 { f |= 64 }
            if !ent.onGround { f |= 128 }
            s.flags = f
            if let sh = ent as? Shulker {
                s.aux = UInt8(clampD(sh.peekAmount * 100, 0, 100))
            }
            states.append(s)
            if let liv, liv.deathTime == 1 {
                g.conn.send(.entityEvent(eid: Int32(ent.id), kind: 2))
            }
        }
        if !states.isEmpty {
            // batches cap at u16 count; nearby entity counts are far below that
            g.conn.send(.entityBatch(dim: dim, states: states))
        }
        let gone = g.knownEntities.subtracting(seen)
        if !gone.isEmpty {
            g.conn.send(.entityRemove(eids: gone.map { Int32($0) }))
            g.knownEntities = seen
        }
    }

    // ---- queries used by GameCore -------------------------------------------------
    /// puppets standing in this world (chunk keep-alive + sim range + spawning)
    public func puppets(in w: World) -> [Player] {
        guests.compactMap { g in
            guard g.ready, let p = g.puppet, p.world === w else { return nil }
            return p
        }
    }

    public func chunkAnchors(_ w: World) -> [(Int, Int)] {
        puppets(in: w).map { (floorDiv(ifloor($0.x), 16), floorDiv(ifloor($0.z), 16)) }
    }

    public func hasPlayers(in w: World) -> Bool {
        !puppets(in: w).isEmpty
    }
}

// =============================================================================
// GUEST
// =============================================================================
public final class NetGuestSession {
    unowned let game: GameCore
    let conn: NetConnection
    public let myName: String
    /// join-flow status surfaced by the UI ("connecting…", error text)
    public private(set) var status = "connecting…"
    public private(set) var joined = false

    private var stopped = false
    private var pendingChunks: [String: (ChunkRecord?) -> Void] = [:]
    /// chunks the host has edits for — everything else regenerates from seed
    private var netModifiedKeys = Set<String>()
    /// host eid → local shadow entity (and reverse, for actions)
    private var shadowByEid: [Int: Entity] = [:]
    private var eidByShadow: [ObjectIdentifier: Int] = [:]
    /// smooth-follow targets applied every guest tick
    private var targets: [Int: NetEntityState] = [:]
    private var playerNames: [Int: String] = [:]
    private var pendingSwing = false
    private var saveTimer = 0

    public init(game: GameCore, conn: NetConnection, name: String) {
        self.game = game
        self.conn = conn
        myName = name
    }

    public func start(skin: Data) {
        conn.onMessage = { [weak self] msg in self?.handle(msg) }
        conn.onClosed = { [weak self] reason in self?.connectionLost(reason) }
        conn.start()
        conn.send(.hello(name: myName, pid: game.settings.playerId ?? "",
                         version: PEBBLE_VERSION, proto: NET_PROTOCOL_VERSION, skin: skin))
    }

    /// leaving voluntarily (Esc → title)
    public func shutdown() {
        if stopped { return }
        sendPlayerSave()
        conn.send(.goodbye)
        stopped = true
        conn.close()
    }

    private func connectionLost(_ reason: String) {
        if stopped { return }
        stopped = true
        status = reason
        if game.netGuest === self { game.netGuest = nil }
        if joined {
            game.exitToTitle()
            game.host?.pushChat("§cDisconnected: \(reason)")
            game.host?.showActionBar("§cDisconnected: \(reason)", 200)
        }
    }

    // ---- inbound ----------------------------------------------------------------
    private func handle(_ msg: NetMsg) {
        if stopped { return }
        // world-touching messages are only valid while we're actually in the
        // host's world — stragglers queued around a disconnect must not land
        switch msg {
        case .welcome, .disconnect, .chatS:
            break
        default:
            guard joined, game.inWorld, game.netGuest === self else { return }
        }
        switch msg {
        case let .welcome(json):
            guard let wel = try? JSONDecoder().decode(NetWelcome.self, from: json) else {
                connectionLost("bad welcome from host")
                return
            }
            netModifiedKeys = Set(wel.modifiedKeys)
            joined = true
            status = "joined"
            if !wel.hostId.isEmpty {
                game.socialStore.recordRecent(id: wel.hostId, name: wel.hostName, how: "you joined")
            }
            game.enterWorldAsGuest(self, wel)
            for (eidStr, name) in wel.players {
                if let eid = Int(eidStr) { addPlayerShadow(eid, name) }
            }

        case let .chunkData(dim, cx, cz, record):
            let key = netChunkKeyStr(Int(dim), Int(cx), Int(cz))
            let cb = pendingChunks.removeValue(forKey: key)
            let rec = record.isEmpty ? nil : decodeWireChunk(record, dim: Int(dim), cx: Int(cx), cz: Int(cz))
            cb?(rec)

        case let .setBlock(dim, x, y, z, cell):
            guard let d = Dim(rawValue: Int(dim)), let w = game.worlds[d] else { return }
            if ProcessInfo.processInfo.environment["PEBBLE_NETDEBUG"] != nil {
                print("[netdbg] guest recv setBlock d\(dim) (\(x),\(y),\(z))=\(cell) loaded=\(w.isLoadedAt(Int(x), Int(z)))")
            }
            netModifiedKeys.insert(netChunkKeyStr(Int(dim), floorDiv(Int(x), 16), floorDiv(Int(z), 16)))
            if w.isLoadedAt(Int(x), Int(z)) {
                w.setBlock(Int(x), Int(y), Int(z), Int(cell), SET_NO_NEIGHBORS)
            }

        case let .entitySpawn(eid, dim, json):
            guard Int(dim) == game.dim.rawValue,
                  let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
                  shadowByEid[Int(eid)] == nil,
                  let e = loadEntity(game.world, obj) else { return }
            e.persistent = true
            game.world.addEntity(e)
            shadowByEid[Int(eid)] = e
            eidByShadow[ObjectIdentifier(e)] = Int(eid)

        case let .entityBatch(dim, states):
            guard Int(dim) == game.dim.rawValue else { return }
            for s in states { targets[Int(s.eid)] = s }

        case let .entityRemove(eids):
            for eid in eids {
                guard let e = shadowByEid[Int(eid)] else { continue }
                // dying entities keep their local death animation; reap after
                if let liv = e as? LivingEntity, liv.deathTime > 0, liv.deathTime < 19 { continue }
                removeShadow(Int(eid))
            }

        case let .entityEvent(eid, kind):
            guard let e = shadowByEid[Int(eid)] as? LivingEntity else { return }
            switch kind {
            case 1: e.hurtTime = 10
            case 2: e.health = 0; e.deathTime = max(1, e.deathTime)
            case 3: e.attackAnim = 1
            default: break
            }

        case let .playerJoin(eid, name, pid, _):
            addPlayerShadow(Int(eid), name)
            if !pid.isEmpty {
                game.socialStore.recordRecent(id: pid, name: name, how: "played together")
            }
            game.host?.pushChat("§e\(name) joined the game")

        case let .playerLeave(eid, _):
            playerNames.removeValue(forKey: Int(eid))
            removeShadow(Int(eid))

        case let .playerStateS(eid, st):
            applyPlayerShadow(Int(eid), st)

        case let .giveItem(stack):
            guard let s = stackFrom(stack), let p = game.player else { return }
            if !p.give(s) && s.count > 0 {
                conn.send(.dropItem(stack: stackJSON(s)))   // inventory full — hand it back
            }

        case let .giveXP(amount):
            game.player?.addXP(Int(amount))

        case let .damage(amount, source):
            applyNetDamage(Double(amount), source)

        case let .timeSync(json):
            guard let sync = try? JSONDecoder().decode(NetTimeSync.self, from: json) else { return }
            for (k, ds) in sync.dims {
                guard let raw = Int(k), let d = Dim(rawValue: raw), let w = game.worlds[d] else { continue }
                w.time = ds.time
                w.dayTime = ds.dayTime
                w.raining = ds.raining
                w.thundering = ds.thundering
                w.weatherTimer = ds.weatherTimer
            }

        case let .sound(name, dim, x, y, z, vol, pitch):
            if Int(dim) == game.dim.rawValue {
                game.host?.playSound(name, Double(x), Double(y), Double(z), Double(vol), Double(pitch))
            }

        case let .particles(kind, dim, x, y, z, count, spread, cell):
            if Int(dim) == game.dim.rawValue {
                game.host?.addParticles(kind, Double(x), Double(y), Double(z), Int(count), Double(spread), Int(cell))
            }

        case let .chatS(text):
            game.host?.pushChat(text)

        case let .beSync(dim, x, y, z, json):
            guard let d = Dim(rawValue: Int(dim)), let w = game.worlds[d],
                  let be = try? JSONDecoder().decode(BlockEntityData.self, from: json) else { return }
            w.setBlockEntity(be)
            _ = (x, y, z)

        case let .disconnect(reason):
            connectionLost(reason)

        default:
            break
        }
    }

    // ---- shadows ------------------------------------------------------------------
    private func addPlayerShadow(_ eid: Int, _ name: String) {
        playerNames[eid] = name
        guard shadowByEid[eid] == nil, game.inWorld else { return }
        let shadow = Player(world: game.world)
        shadow.netPickupSuppressed = true
        shadow.setPos(game.player.x, game.player.y, game.player.z)
        game.world.addEntity(shadow)
        shadowByEid[eid] = shadow
        eidByShadow[ObjectIdentifier(shadow)] = eid
    }

    private func removeShadow(_ eid: Int) {
        guard let e = shadowByEid.removeValue(forKey: eid) else { return }
        eidByShadow.removeValue(forKey: ObjectIdentifier(e))
        targets.removeValue(forKey: eid)
        e.world.removeEntity(e)
    }

    private func applyPlayerShadow(_ eid: Int, _ st: NetPlayerState) {
        guard let shadow = shadowByEid[eid] as? Player else {
            if playerNames[eid] != nil { addPlayerShadow(eid, playerNames[eid]!) }
            return
        }
        // players in other dimensions vanish locally until they come back
        if Int(st.dim) != game.dim.rawValue {
            if shadow.world.entityById[shadow.id] != nil { shadow.world.removeEntity(shadow) }
            return
        }
        if shadow.world.entityById[shadow.id] == nil {
            shadow.world = game.world
            shadow.setPos(st.x, st.y, st.z)
            game.world.addEntity(shadow)
        }
        var t = NetEntityState()
        t.eid = Int32(eid)
        t.x = st.x; t.y = st.y; t.z = st.z
        t.yaw = st.yaw; t.pitch = st.pitch; t.headYaw = st.yaw
        t.flags = (st.flags & 1) != 0 ? 1 : 0
        targets[eid] = t
        shadow.sneaking = st.flags & 2 != 0
        shadow.sprinting = st.flags & 4 != 0
        shadow.usingItem = st.flags & 8 != 0
        if st.flags & 16 != 0 { shadow.attackAnim = 1 }
        shadow.elytraFlying = st.flags & 64 != 0
        shadow.health = Double(st.health)
        if st.heldId >= 0 && st.heldId < Int32(itemDefs.count) {
            shadow.mainHand = ItemStack(Int(st.heldId), 1, damage: Int(st.heldMeta))
        } else {
            shadow.mainHand = nil
        }
        applyGearMirror(shadow, st)
        // blocking pose needs to know which hand holds the raised item
        if shadow.usingItem {
            let offIsShield = shadow.offHand.map { itemDef($0.id).name == "shield" } ?? false
            shadow.useItemHand = offIsShield ? "off" : "main"
        }
    }

    /// interpolate shadows toward their net targets + advance local-only anims.
    /// runs once per guest tick.
    public func animTick() {
        for (eid, e) in shadowByEid {
            e.prevX = e.x; e.prevY = e.y; e.prevZ = e.z
            e.prevYaw = e.yaw; e.prevPitch = e.pitch
            e.age += 1
            if let t = targets[eid] {
                // half-life smoothing: converges fast but never pops
                e.x += (t.x - e.x) * 0.5
                e.y += (t.y - e.y) * 0.5
                e.z += (t.z - e.z) * 0.5
                e.yaw += wrapAngle(Double(t.yaw) - e.yaw) * 0.5
                e.pitch += (Double(t.pitch) - e.pitch) * 0.5
                e.onGround = t.flags & 1 != 0
                if let liv = e as? LivingEntity {
                    liv.headYaw += wrapAngle(Double(t.headYaw) - liv.headYaw) * 0.5
                    if t.flags & 32 != 0 && liv.hurtTime <= 0 { liv.hurtTime = 10 }
                    if t.flags & 64 != 0 && liv.attackAnim <= 0 { liv.attackAnim = 1 }
                    if t.flags & 2 != 0, let mob = e as? Mob, mob.target == nil {
                        mob.target = game.player   // renderer poses "aiming" off target presence
                    } else if t.flags & 2 == 0, let mob = e as? Mob {
                        mob.target = nil
                    }
                    if let sh = e as? Shulker { sh.peekAmount = Double(t.aux) / 100 }
                    e.data.grazing = t.flags & 4 != 0
                    (e as? Mob)?.sitting = t.flags & 8 != 0
                }
            }
            if let liv = e as? LivingEntity {
                let ddx = e.x - e.prevX, ddz = e.z - e.prevZ
                let speed = (ddx * ddx + ddz * ddz).squareRoot()
                liv.limbAmp += (min(1, speed * 2.5) - liv.limbAmp) * 0.4
                liv.limbSwing += liv.limbAmp * 1.2
                if liv.hurtTime > 0 { liv.hurtTime -= 1 }
                if liv.attackAnim > 0 { liv.attackAnim = max(0, liv.attackAnim - 0.125) }
                if liv.deathTime > 0 {
                    liv.deathTime += 1
                    if liv.deathTime >= 19 { removeShadow(eid) }
                }
            }
        }
    }

    // ---- outbound ------------------------------------------------------------------
    public func fetchChunk(_ w: World, _ cx: Int, _ cz: Int, _ cb: @escaping (ChunkRecord?) -> Void) {
        let key = netChunkKeyStr(w.dim.rawValue, cx, cz)
        if !netModifiedKeys.contains(key) || stopped {
            cb(nil)   // pristine — regenerate locally from the seed
            return
        }
        pendingChunks[key] = cb
        conn.send(.chunkReq(dim: UInt8(w.dim.rawValue), cx: Int32(cx), cz: Int32(cz)))
    }

    public func markSwing() { pendingSwing = true }

    public func sendState() {
        guard let p = game.player else { return }
        conn.send(.playerState(netStateOf(p, dim: game.dim, swing: pendingSwing)))
        pendingSwing = false
        saveTimer += 1
        if saveTimer >= 600 {   // 30 s
            saveTimer = 0
            sendPlayerSave()
        }
    }

    public func sendPlayerSave() {
        guard joined, !stopped, let p = game.player else { return }
        let payload: [String: Any] = ["dim": game.dim.rawValue, "data": p.save()]
        if let json = try? JSONSerialization.data(withJSONObject: payload) {
            conn.send(.playerSave(json: json))
        }
    }

    public func sendBreak(_ x: Int, _ y: Int, _ z: Int) {
        conn.send(.blockBreak(dim: UInt8(game.dim.rawValue), x: Int32(x), y: Int32(y), z: Int32(z),
                              held: stackJSON(game.player?.mainHand)))
        // local prediction: clear it now; drops/sounds come back from the host
        game.world.setBlock(x, y, z, 0, SET_NO_NEIGHBORS)
    }

    public func sendUseBlock(_ hit: RaycastHit, sneaking: Bool) {
        conn.send(.useBlock(dim: UInt8(game.dim.rawValue),
                            x: Int32(hit.x), y: Int32(hit.y), z: Int32(hit.z), face: UInt8(hit.face),
                            px: Float(hit.px), py: Float(hit.py), pz: Float(hit.pz),
                            sneaking: sneaking, held: stackJSON(game.player?.mainHand)))
    }

    public func sendUseItem() {
        conn.send(.useItem(held: stackJSON(game.player?.mainHand)))
    }

    public func sendStopUsing(_ ticks: Int) {
        conn.send(.stopUsing(useTicks: Int32(ticks), held: stackJSON(game.player?.usingHandStack)))
    }

    public func sendUseEntity(_ e: Entity) -> Bool {
        guard let eid = eidByShadow[ObjectIdentifier(e)] else { return false }
        conn.send(.useEntity(eid: Int32(eid)))
        return true
    }

    public func sendAttack(_ e: Entity) -> Bool {
        guard let eid = eidByShadow[ObjectIdentifier(e)] else { return false }
        conn.send(.attack(eid: Int32(eid), held: stackJSON(game.player?.mainHand)))
        return true
    }

    public func sendDrop(_ stack: ItemStack) {
        conn.send(.dropItem(stack: stackJSON(stack)))
    }

    public func sendChat(_ text: String) {
        conn.send(.chat(text: text))
    }

    // ---- local effects ---------------------------------------------------------------
    /// host-computed final damage (armor already applied there)
    private func applyNetDamage(_ amount: Double, _ source: String) {
        guard let p = game.player, p.health > 0, game.inWorld else { return }
        p.health = max(0, p.health - amount)
        p.hurtTime = 10
        game.host?.playSound("entity.player.hurt", p.x, p.y, p.z, 1, 1)
        if p.health <= 0 {
            p.data.deathCause = source
            p.deathTime = 1
            // drop everything at the death spot (host spawns the items)
            if !p.world.rule("keepInventory") {
                for i in 0..<p.inventory.count {
                    if let s = p.inventory[i] { sendDrop(s) }
                    p.inventory[i] = nil
                }
                for i in 0..<p.armor.count {
                    if let s = p.armor[i] { sendDrop(s) }
                    p.armor[i] = nil
                }
                if let s = p.offHand { sendDrop(s); p.offHand = nil }
            }
            sendPlayerSave()
        }
    }
}
