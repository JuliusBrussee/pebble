import Foundation
import PebbleAudioCore
import PebbleCore
import PebbleRenderABI
import PebbleRendererVulkan
import PebbleResources
import PebbleUI

private struct WinSectionKey: Hashable {
    let cx: Int
    let sy: Int
    let cz: Int
}

private struct WinSectionMeshes {
    let minY: Int
    var opaque: MeshHandle?
    var cutout: MeshHandle?
    var translucent: MeshHandle?
}

private struct WinEntityResources {
    let mesh: MeshHandle
    let texture: TextureHandle
    let vertexCount: UInt32
    let scale: Float
    let model: MobModel
}

private struct WinParticle {
    var position: SIMD3<Double>
    var velocity: SIMD3<Double>
    var age: Double = 0
    var lifetime: Double
    var size: Double
    var gravity: Double
    var tile: Int
    var color: SIMD3<Float>
    var light: Float
    var shrink: Bool
}

final class WindowsGameHost: GameHost {
    let renderer: VulkanRendererBackend
    let atlas: TextureHandle
    let uiAtlas: TextureHandle
    private let mixer = AudioMixer()
    private var audioOutput: NativeMixerOutput?
    private var sections: [WinSectionKey: WinSectionMeshes] = [:]
    private var screenOpen = false
    private var screenKind = "pause"
    private var textBuffer = ""
    private let uiCanvas = UICanvasCPU(width: 1, height: 1)
    private var uiMesh: MeshHandle?
    private var breakingMesh: MeshHandle?
    private var breakingStage = -1
    private var cubeEntityMeshes: [Int: MeshHandle] = [:]
    private var entityResources: [String: WinEntityResources] = [:]
    private var particles: [WinParticle] = []
    private var particleMesh: MeshHandle?
    private var particleClock: Double?
    private var particleRandom: UInt32 = 0x70656262
    private var actionBarText = ""
    private var actionBarFrames = 0
    private var chatLines: [String] = []
    private var bossBars: [BossBarInfo] = []
    private var toasts: [(definition: AdvancementDef, frames: Int)] = []
    private let resourcePacks: ResourcePackStack
    private let customSkinURL: URL
    private var atlasSlices: [[UInt8]] = []
    private var atlasAnimations: [PortableTileAnimation] = []
    private var atlasAnimationFrames: [Int] = []
    private var lastAtlasTick = -1
    private let uiAtlasWidth: Int
    private let uiAtlasHeight: Int
    private var musicMood = ""
    private var musicCooldown = 0
    private var discPlaying = false
    private var screenMousePosition = SIMD2<Float>(0, 0)
    private var carriedStack: ItemStack?
    private var lastScreenSize = SIMD2<Float>(1, 1)
    private var screenData: ScreenData?
    private var screenMessage = ""
    private(set) var exitRequested = false
    private var screenReturnKind = "title"
    private weak var tradingMob: Mob?
    private var externalContainerCommit: (() -> Void)?
    private var signLine = 0
    private weak var activeGame: GameCore?
    private var craftingGrid: [ItemStack?] = Array(repeating: nil, count: 9)
    private var inventoryCraftingGrid: [ItemStack?] = Array(repeating: nil, count: 4)
    private var enchantingItem: ItemStack?
    private var enchantingLapis: ItemStack?
    private var enchantingSeed = 0x504542
    private var enchantingBookshelves = 0
    private var anvilLeft: ItemStack?
    private var anvilRight: ItemStack?
    private var anvilName = ""
    private var grindstoneTop: ItemStack?
    private var grindstoneBottom: ItemStack?
    private var stonecutterInput: ItemStack?
    private var stonecutterSelection = -1
    private var smithingTemplate: ItemStack?
    private var smithingBase: ItemStack?
    private var smithingAddition: ItemStack?
    private var beaconPayment: ItemStack?
    private var beaconPendingPower: String?
    private var creativeScrollRow = 0
    private var creativeSearch = ""
    private var hoveredStack: ItemStack?
    private var subtitles: [(text: String, frames: Int)] = []
    private var titleWorldSelection = 0
    private var titleWorldOffset = 0
    private var pendingWorldDeleteID: String?
    private var createWorldName = ""
    private var createWorldSeed = ""
    private var createWorldField = 0
    private var createWorldMode = 0
    private var multiplayerAddress = "127.0.0.1:25565"
    private var multiplayerName = "Player"
    private var multiplayerField = 0
    private var multiplayerMessage = ""

    init(renderer: VulkanRendererBackend, resourcePacks: ResourcePackStack,
         customSkinURL: URL) throws {
        self.renderer = renderer
        self.resourcePacks = resourcePacks
        self.customSkinURL = customSkinURL
        let packed = resourcePacks.blockAtlasResult(fallback: PebbleCore.buildAtlas())
        let built = packed.atlas
        atlasSlices = built.pixels
        atlasAnimations = packed.animations
        atlasAnimationFrames = [Int](repeating: -1, count: packed.animations.count)
        atlas = try renderer.createTexture(RenderTextureData(
            width: TILE, height: TILE, layers: built.count,
            format: .rgba8Unorm, bytes: built.pixels.flatMap { $0 }))
        try renderer.installAtlas(atlas)
        initIcons(built)
        itemIconOverride = { resourcePacks.itemIcon($0) }
        resetIconCache()
        let columns = 32
        let rows = max(1, (itemDefs.count + 1 + columns - 1) / columns)
        uiAtlasWidth = columns * 16
        uiAtlasHeight = rows * 16
        var uiPixels = [UInt8](repeating: 0, count: uiAtlasWidth * uiAtlasHeight * 4)
        for y in 0..<16 {
            for x in 0..<16 {
                let offset = (y * uiAtlasWidth + x) * 4
                uiPixels[offset] = 255; uiPixels[offset + 1] = 255
                uiPixels[offset + 2] = 255; uiPixels[offset + 3] = 255
            }
        }
        for itemID in itemDefs.indices {
            let cell = itemID + 1
            let originX = (cell % columns) * 16
            let originY = (cell / columns) * 16
            let icon = itemIconPixels(itemID)
            for y in 0..<16 {
                let source = y * 16 * 4
                let destination = ((originY + y) * uiAtlasWidth + originX) * 4
                uiPixels.replaceSubrange(destination..<(destination + 16 * 4),
                                         with: icon[source..<(source + 16 * 4)])
            }
        }
        uiAtlas = try renderer.createTexture(RenderTextureData(
            width: uiAtlasWidth, height: uiAtlasHeight,
            format: .rgba8Unorm, bytes: uiPixels))
        try renderer.installUITexture(uiAtlas)
        uiCanvas.solidUV = SIMD2<Float>(8 / Float(uiAtlasWidth), 8 / Float(uiAtlasHeight))
        audioOutput = try? NativeMixerOutput(mixer: mixer)
        try? audioOutput?.start()
    }

    deinit {
        audioOutput?.stop()
        if let uiMesh { renderer.destroyMesh(uiMesh) }
        if let particleMesh { renderer.destroyMesh(particleMesh) }
        if let breakingMesh { renderer.destroyMesh(breakingMesh) }
        for mesh in cubeEntityMeshes.values { renderer.destroyMesh(mesh) }
        for resources in entityResources.values {
            renderer.destroyMesh(resources.mesh)
            renderer.destroyTexture(resources.texture)
        }
        renderer.destroyTexture(atlas)
        renderer.destroyTexture(uiAtlas)
    }

    func buildFrame(game: GameCore, target: RenderTarget,
                    partial: Double, timeSec: Double) -> FramePacket {
        activeGame = game
        mixer.setVolumes(master: game.settings.volumes["master"] ?? 0.8,
                         categories: game.settings.volumes.filter { $0.key != "master" })
        tickAtlasAnimations(timeSec: timeSec)
        guard game.hasWorld() else {
            return emptyFrame(game: game, target: target, timeSec: timeSec)
        }
        let cam = game.camState(partial, timeSec: timeSec)
        let aspect = Float(target.width) / Float(max(1, target.height))
        let far = max(256, Float(game.settings.renderDistance) * 16 * 1.6)
        let projection = mat4Perspective(fovYRad: Float(cam.fov * .pi / 180), aspect: aspect,
                                         near: 0.05, far: far)
        let direction = SIMD3<Float>(
            Float(detCos(cam.pitch) * -detSin(cam.yaw)),
            Float(detSin(-cam.pitch)),
            Float(detCos(cam.pitch) * detCos(cam.yaw)))
        let right = normalized(SIMD3<Float>(direction.z, 0, -direction.x),
                               fallback: SIMD3<Float>(1, 0, 0))
        let cameraUp = normalized(cross(right, direction), fallback: SIMD3<Float>(0, 1, 0))
        let view = mat4LookDir(eye: .zero, dir: direction, up: SIMD3<Float>(0, 1, 0))
        let viewProjection = projection * view
        let world = game.world
        let ambient = Float(Double(world.info.ambientLight) / 15)
        let sunHeight = detCos(world.sunAngle() * .pi * 2)
        let dayLight = Float(world.dim == .overworld
            ? max(0.06, min(1, sunHeight * 2 + 0.5))
            : 0.75)
        let fogColor: SIMD4<Float>
        switch world.dim {
        case .nether: fogColor = SIMD4<Float>(0.34, 0.08, 0.035, 1)
        case .end: fogColor = SIMD4<Float>(0.07, 0.06, 0.1, 1)
        default: fogColor = SIMD4<Float>(0.55 * dayLight, 0.7 * dayLight, 0.95 * dayLight, 1)
        }
        let renderDistance = Float(game.settings.renderDistance) * 16
        let sunAngle = world.sunAngle()
        let sunDirection = SIMD3<Float>(Float(-detSin(sunAngle * .pi * 2 + .pi)),
                                        Float(detCos(sunAngle * .pi * 2)), 0.18)
        let shadowsOn = game.settings.shadows && world.dim == .overworld && dayLight > 0.1 && sunDirection.y > 0.05
        let shadowMatrix: Mat4f
        if shadowsOn {
            let lightView = mat4LookDir(eye: sunDirection * 120, dir: -sunDirection,
                                        up: SIMD3<Float>(0, 1, 0))
            shadowMatrix = mat4Ortho(l: -72, r: 72, b: -72, t: 72, n: 1, f: 320) * lightView
        } else {
            shadowMatrix = mat4Identity()
        }
        let camera = CameraState(viewProj: abi(viewProjection), invViewProj: .identity,
                                 shadowMat: abi(shadowMatrix))
        let uniforms = FrameUniforms(
            time: Float(timeSec), dayLight: dayLight,
            gamma: Float(game.settings.gamma + cam.nightVision * 1.6), ambient: ambient,
            fogStart: renderDistance * 0.55, fogEnd: renderDistance * 0.95,
            fogColor: fogColor, sunDir: SIMD4<Float>(sunDirection, 0),
            shadowsOn: shadowsOn, ultraOn: game.settings.shader == "ultra")
        var builder = FrameBuilder(camera: camera, uniforms: uniforms)
        let shared = ChunkSharedUniforms(
            viewProj: camera.viewProj, shadowMat: camera.shadowMat,
            light: SIMD4<Float>(dayLight, uniforms.gamma, ambient, shadowsOn ? 1 : 0),
            fog: SIMD4<Float>(uniforms.fogStart, uniforms.fogEnd, 0, 1),
            fogColor: fogColor,
            misc: SIMD4<Float>(Float(timeSec), game.settings.clouds ? 1 : 0,
                               Float(world.dim.rawValue),
                               (world.raining ? 1 : 0) + (uniforms.ultraOn ? 2 : 0)))
        let maximumDistanceSquared = (renderDistance + 24) * (renderDistance + 24)
        for (key, section) in sections {
            let origin = SIMD3<Float>(Float(Double(key.cx * 16) - cam.x),
                                      Float(Double(section.minY + key.sy * 16) - cam.y),
                                      Float(Double(key.cz * 16) - cam.z))
            let distanceSquared = (origin.x + 8) * (origin.x + 8) + (origin.z + 8) * (origin.z + 8)
            if distanceSquared > maximumDistanceSquared { continue }
            func add(_ handle: MeshHandle?, _ pipeline: PipelineID, _ translucent: Bool) {
                guard let handle else { return }
                let fog = SIMD4<Float>(uniforms.fogStart, uniforms.fogEnd,
                                       pipeline == .cutout ? 0.35 : 0, translucent ? 0.82 : 1)
                let constants = ChunkDrawConstants(
                    shared: ChunkSharedUniforms(viewProj: shared.viewProj, shadowMat: shared.shadowMat,
                                                light: shared.light, fog: fog,
                                                fogColor: shared.fogColor, misc: shared.misc),
                    origin: SIMD4<Float>(origin, 0))
                builder.addDraw(
                    pass: .world, pipeline: pipeline, mesh: handle,
                    depthBucket: translucent
                        ? FrameBuilder.translucentDepthBucket(distanceSquared: distanceSquared)
                        : FrameBuilder.opaqueDepthBucket(distanceSquared: distanceSquared),
                    indexRange: 0..<indexCount(handle),
                    textures: [TextureBinding(index: 3, texture: atlas, sampler: nil)],
                    pushConstants: RenderBytes.copy(constants))
                if pipeline == .opaque && shadowsOn {
                    builder.addDraw(pass: .shadow, pipeline: .shadow, mesh: handle,
                                    depthBucket: FrameBuilder.opaqueDepthBucket(distanceSquared: distanceSquared),
                                    indexRange: 0..<indexCount(handle),
                                    pushConstants: RenderBytes.copy(constants))
                }
            }
            add(section.opaque, .opaque, false)
            add(section.cutout, .cutout, false)
            add(section.translucent, .translucent, true)
        }
        appendBreakingOverlay(game: game, cameraPosition: SIMD3<Double>(cam.x, cam.y, cam.z),
                              shared: shared, builder: &builder)
        appendCubeEntities(game: game, cameraPosition: SIMD3<Double>(cam.x, cam.y, cam.z),
                           partial: partial, shared: shared, builder: &builder)
        appendEntities(game: game, cameraPosition: SIMD3<Double>(cam.x, cam.y, cam.z),
                       partial: partial, uniforms: uniforms, builder: &builder)
        appendParticles(game: game, cameraPosition: SIMD3<Double>(cam.x, cam.y, cam.z),
                        viewProjection: camera.viewProj, right: right, up: cameraUp,
                        dayLight: dayLight, timeSec: timeSec, builder: &builder)
        appendViewmodel(game: game, direction: direction, right: right, up: cameraUp,
                        uniforms: uniforms, partial: partial, builder: &builder)
        appendUI(game: game, target: target, builder: &builder)
        return builder.finish(includeEmptyPasses: false)
    }

    private func tickAtlasAnimations(timeSec: Double) {
        guard !atlasAnimations.isEmpty else { return }
        let tick = Int(timeSec * 20)
        guard tick != lastAtlasTick else { return }
        lastAtlasTick = tick
        var changed = false
        for index in atlasAnimations.indices {
            let animation = atlasAnimations[index]
            let cycleTicks = max(1, animation.ticks.reduce(0, +))
            var phase = ((tick % cycleTicks) + cycleTicks) % cycleTicks
            var orderIndex = 0
            for candidate in animation.ticks.indices {
                let duration = max(1, animation.ticks[candidate])
                if phase < duration {
                    orderIndex = candidate
                    break
                }
                phase -= duration
            }
            guard orderIndex < animation.order.count else { continue }
            let frame = animation.order[orderIndex]
            guard frame != atlasAnimationFrames[index],
                  animation.frames.indices.contains(frame),
                  atlasSlices.indices.contains(animation.slice) else { continue }
            atlasAnimationFrames[index] = frame
            atlasSlices[animation.slice] = animation.frames[frame]
            changed = true
        }
        guard changed else { return }
        try? renderer.updateTexture(atlas, data: RenderTextureData(
            width: TILE, height: TILE, layers: atlasSlices.count,
            format: .rgba8Unorm, bytes: atlasSlices.flatMap { $0 }))
    }

    private var meshIndexCounts: [MeshHandle: UInt32] = [:]
    private func indexCount(_ handle: MeshHandle) -> UInt32 { meshIndexCounts[handle] ?? 0 }

    func uploadMesh(_ cx: Int, _ sy: Int, _ cz: Int, _ minY: Int, _ mesh: MeshOutput) {
        let key = WinSectionKey(cx: cx, sy: sy, cz: cz)
        if let old = sections.removeValue(forKey: key) { destroy(old) }
        func upload(_ layer: MeshLayer) -> MeshHandle? {
            guard layer.count > 0, !layer.idx.isEmpty else { return nil }
            let vertexBytes = layer.data.withUnsafeBytes { Array($0) }
            let indexBytes = layer.idx.withUnsafeBytes { Array($0) }
            guard let handle = try? renderer.createMesh(RenderMeshData(
                vertexLayout: .chunk, vertexBytes: vertexBytes,
                indexBytes: indexBytes, indexFormat: .uint32)) else { return nil }
            meshIndexCounts[handle] = UInt32(layer.idx.count)
            return handle
        }
        let uploaded = WinSectionMeshes(minY: minY, opaque: upload(mesh.opaque),
                                        cutout: upload(mesh.cutout), translucent: upload(mesh.translucent))
        if uploaded.opaque != nil || uploaded.cutout != nil || uploaded.translucent != nil {
            sections[key] = uploaded
        }
    }

    func removeChunkMeshes(_ cx: Int, _ cz: Int, _ count: Int) {
        for sy in 0..<count {
            if let removed = sections.removeValue(forKey: WinSectionKey(cx: cx, sy: sy, cz: cz)) { destroy(removed) }
        }
    }

    func clearAllSections() {
        for section in sections.values { destroy(section) }
        sections.removeAll()
    }

    private func destroy(_ section: WinSectionMeshes) {
        for handle in [section.opaque, section.cutout, section.translucent].compactMap({ $0 }) {
            meshIndexCounts.removeValue(forKey: handle)
            renderer.destroyMesh(handle)
        }
    }

    private func abi(_ matrix: Mat4f) -> ABIMat4 {
        ABIMat4(c0: matrix[0], c1: matrix[1], c2: matrix[2], c3: matrix[3])
    }

    private func appendEntities(game: GameCore, cameraPosition: SIMD3<Double>, partial: Double,
                                uniforms: FrameUniforms, builder: inout FrameBuilder) {
        let maximumDistanceSquared = game.settings.entityDistance * game.settings.entityDistance
        for reference in game.world.entities {
            guard let entity = reference as? Entity, !entity.dead else { continue }
            if entity === game.player && game.perspective == 0 { continue }
            let dx = entity.x - cameraPosition.x, dz = entity.z - cameraPosition.z
            let distanceSquared = dx * dx + dz * dz
            if distanceSquared > maximumDistanceSquared { continue }
            guard let modelName = entityModelName(entity),
                  let resources = resourcesForEntity(modelName) else { continue }
            let x = entity.prevX + (entity.x - entity.prevX) * partial
            let y = entity.prevY + (entity.y - entity.prevY) * partial
            let z = entity.prevZ + (entity.z - entity.prevZ) * partial
            let yaw = entity.prevYaw + wrappedAngle(entity.yaw - entity.prevYaw) * partial
            let babyScale: Float = entity.data.baby == true ? 0.5 : 1
            var model = mat4Identity()
            model = mat4Translate(model, Float(x - cameraPosition.x), Float(y - cameraPosition.y),
                                  Float(z - cameraPosition.z))
            model = mat4RotateY(model, Float(.pi - yaw))
            let scale = resources.scale * babyScale
            model = mat4Scale(model, scale, scale, scale)
            let bx = Int(entity.x.rounded(.down))
            let by = Int((entity.y + entity.height * 0.5).rounded(.down))
            let bz = Int(entity.z.rounded(.down))
            let sky = Float(game.world.getSkyLight(bx, by, bz))
            let block = Float(game.world.getBlockLight(bx, by, bz))
            let hurt = entity.invulnTicks > 0 ? min(0.5, Float(entity.invulnTicks) / 20) : 0
            let constants = EntityDrawPacketConstants(
                model: abi(model),
                light: SIMD4<Float>(sky, block, uniforms.dayLight, uniforms.gamma),
                misc: SIMD4<Float>(uniforms.ambient, 1, uniforms.fogStart, uniforms.fogEnd),
                overlay: SIMD4<Float>(1, 0.2, 0.2, hurt),
                fogColor: uniforms.fogColor)
            let partMatrices = entityPartMatrices(entity, model: resources.model,
                                                  partial: partial)
            var packet = RenderBytes.copy(constants)
            packet.append(contentsOf: RenderBytes.copy(partMatrices))
            builder.addDraw(
                pass: .entities, pipeline: .entity, mesh: resources.mesh,
                depthBucket: FrameBuilder.opaqueDepthBucket(distanceSquared: Float(distanceSquared)),
                vertexRange: 0..<resources.vertexCount,
                textures: [TextureBinding(index: 0, texture: resources.texture, sampler: nil)],
                pushConstants: packet)
        }
    }

    private func appendBreakingOverlay(game: GameCore, cameraPosition: SIMD3<Double>,
                                       shared: ChunkSharedUniforms, builder: inout FrameBuilder) {
        guard let player = game.player, player.breakingProgress >= 0 else { return }
        let stage = min(9, max(0, Int(player.breakingProgress * 10)))
        if breakingMesh == nil || breakingStage != stage {
            let meshData = breakingOverlayMesh(stage: stage)
            if let breakingMesh { try? renderer.updateMesh(breakingMesh, data: meshData) }
            else { breakingMesh = try? renderer.createMesh(meshData) }
            breakingStage = stage
        }
        guard let breakingMesh else { return }
        let origin = SIMD3<Float>(Float(Double(player.breakingX) - cameraPosition.x),
                                  Float(Double(player.breakingY) - cameraPosition.y),
                                  Float(Double(player.breakingZ) - cameraPosition.z))
        let constants = ChunkDrawConstants(shared: shared, origin: SIMD4<Float>(origin, 0))
        builder.addDraw(pass: .world, pipeline: .translucent, mesh: breakingMesh,
                        depthBucket: 0, indexRange: 0..<36,
                        textures: [TextureBinding(index: 3, texture: atlas, sampler: nil)],
                        pushConstants: RenderBytes.copy(constants))
    }

    private func breakingOverlayMesh(stage: Int) -> RenderMeshData {
        let layer = UInt32(tileId("destroy_\(stage)"))
        let packedA = layer | (3 << 15) | (15 << 17) | (15 << 21)
        let packedB: UInt32 = 0x00ffffff
        let low: Float = -0.003, high: Float = 1.003
        let faces: [([SIMD3<Float>], UInt32)] = [
            ([SIMD3(low, low, low), SIMD3(high, low, low), SIMD3(high, high, low), SIMD3(low, high, low)], 0),
            ([SIMD3(high, low, high), SIMD3(low, low, high), SIMD3(low, high, high), SIMD3(high, high, high)], 1),
            ([SIMD3(low, low, high), SIMD3(low, low, low), SIMD3(low, high, low), SIMD3(low, high, high)], 2),
            ([SIMD3(high, low, low), SIMD3(high, low, high), SIMD3(high, high, high), SIMD3(high, high, low)], 3),
            ([SIMD3(low, high, low), SIMD3(high, high, low), SIMD3(high, high, high), SIMD3(low, high, high)], 4),
            ([SIMD3(low, low, high), SIMD3(high, low, high), SIMD3(high, low, low), SIMD3(low, low, low)], 5),
        ]
        let uvs = [SIMD2<Float>(0, 1), SIMD2<Float>(1, 1), SIMD2<Float>(1, 0), SIMD2<Float>(0, 0)]
        var vertices: [ChunkVertex] = []
        var indices: [UInt32] = []
        for (faceIndex, face) in faces.enumerated() {
            let base = UInt32(vertices.count)
            for index in 0..<4 {
                let position = face.0[index], uv = uvs[index]
                vertices.append(ChunkVertex(x: position.x, y: position.y, z: position.z,
                                            u: uv.x, v: uv.y,
                                            a: packedA | (face.1 << 12), b: packedB))
            }
            indices.append(contentsOf: [base, base + 1, base + 2, base + 2, base + 3, base])
            _ = faceIndex
        }
        return RenderMeshData(vertexLayout: .chunk,
                              vertexBytes: RenderBytes.copy(vertices),
                              indexBytes: RenderBytes.copy(indices), indexFormat: .uint32)
    }

    private func appendCubeEntities(game: GameCore, cameraPosition: SIMD3<Double>, partial: Double,
                                    shared: ChunkSharedUniforms, builder: inout FrameBuilder) {
        for reference in game.world.entities {
            guard let entity = reference as? Entity, !entity.dead else { continue }
            let cell: Int
            let emissive: Bool
            if let falling = entity as? FallingBlockEntity {
                cell = falling.blockCell; emissive = false
            } else if let tnt = entity as? TNTEntity {
                cell = Int(PebbleCore.cell(B.tnt))
                emissive = (tnt.fuse / 5).isMultiple(of: 2)
            } else { continue }
            guard cell >> 4 > 0, let mesh = cubeEntityMesh(cell: cell, emissive: emissive) else { continue }
            let x = entity.prevX + (entity.x - entity.prevX) * partial
            let y = entity.prevY + (entity.y - entity.prevY) * partial
            let z = entity.prevZ + (entity.z - entity.prevZ) * partial
            let origin = SIMD4<Float>(Float(x - cameraPosition.x - 0.49),
                                      Float(y - cameraPosition.y),
                                      Float(z - cameraPosition.z - 0.49), 0)
            let constants = ChunkDrawConstants(shared: shared, origin: origin)
            let distance = Float((x - cameraPosition.x) * (x - cameraPosition.x) +
                                 (z - cameraPosition.z) * (z - cameraPosition.z))
            builder.addDraw(pass: .world, pipeline: .opaque, mesh: mesh,
                            depthBucket: FrameBuilder.opaqueDepthBucket(distanceSquared: distance),
                            indexRange: 0..<36,
                            textures: [TextureBinding(index: 3, texture: atlas, sampler: nil)],
                            pushConstants: RenderBytes.copy(constants))
        }
    }

    private func cubeEntityMesh(cell: Int, emissive: Bool) -> MeshHandle? {
        let key = cell | (emissive ? 1 << 30 : 0)
        if let cached = cubeEntityMeshes[key] { return cached }
        let id = cell >> 4, metadata = cell & 15
        guard id > 0 && id < blockDefs.count else { return nil }
        let definition = blockDefs[id]
        let faces: [([SIMD3<Float>], Int)] = [
            ([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)], 0),
            ([SIMD3(1, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 1, 1), SIMD3(1, 1, 1)], 1),
            ([SIMD3(0, 0, 1), SIMD3(0, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 1, 1)], 2),
            ([SIMD3(1, 0, 0), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(1, 1, 0)], 3),
            ([SIMD3(0, 1, 0), SIMD3(1, 1, 0), SIMD3(1, 1, 1), SIMD3(0, 1, 1)], 4),
            ([SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 0, 0)], 5),
        ]
        let uvs = [SIMD2<Float>(0, 1), SIMD2<Float>(1, 1), SIMD2<Float>(1, 0), SIMD2<Float>(0, 0)]
        var vertices: [ChunkVertex] = []
        var indices: [UInt32] = []
        for (corners, face) in faces {
            let layer = definition.texFn?(metadata, face)
                ?? (definition.tex.isEmpty ? 0 : Int(definition.tex[min(face, definition.tex.count - 1)]))
            let light = emissive ? 15 : 10
            let packedA = UInt32(layer) | (UInt32(face) << 12) | (3 << 15) |
                (15 << 17) | (UInt32(light) << 21) | (emissive ? 1 << 25 : 0)
            let base = UInt32(vertices.count)
            for index in 0..<4 {
                let p = corners[index], uv = uvs[index]
                vertices.append(ChunkVertex(x: p.x, y: p.y, z: p.z, u: uv.x, v: uv.y,
                                            a: packedA, b: 0x00ffffff))
            }
            indices.append(contentsOf: [base, base + 1, base + 2, base + 2, base + 3, base])
        }
        let data = RenderMeshData(vertexLayout: .chunk, vertexBytes: RenderBytes.copy(vertices),
                                  indexBytes: RenderBytes.copy(indices), indexFormat: .uint32)
        guard let mesh = try? renderer.createMesh(data) else { return nil }
        cubeEntityMeshes[key] = mesh
        return mesh
    }

    private func resourcesForEntity(_ name: String) -> WinEntityResources? {
        if let cached = entityResources[name] { return cached }
        let geometry = buildEntityGeometry(name)
        guard let mesh = try? renderer.createMesh(RenderMeshData(
            vertexLayout: .entity, vertexBytes: geometry.verts.withUnsafeBytes { Array($0) },
            indexBytes: [], indexFormat: .uint32)) else { return nil }
        let packedImage = name == "player"
            ? resourcePacks.playerSkin(customURL: customSkinURL)
            : resourcePacks.entityImage(geometry.model.packTex,
                                        stack: geometry.model.packTexStack,
                                        tints: geometry.model.packTexTints)
        let validPackedImage = packedImage.flatMap { image in
            image.width * geometry.model.texH == image.height * geometry.model.texW ? image : nil
        }
        let skinWidth = validPackedImage?.width ?? geometry.skin.w
        let skinHeight = validPackedImage?.height ?? geometry.skin.h
        let skinPixels = validPackedImage?.pixels ?? geometry.skin.data
        guard let texture = try? renderer.createTexture(RenderTextureData(
            width: skinWidth, height: skinHeight,
            format: .rgba8Unorm, bytes: skinPixels)) else {
            renderer.destroyMesh(mesh)
            return nil
        }
        let resources = WinEntityResources(mesh: mesh, texture: texture,
                                           vertexCount: UInt32(geometry.vertexCount),
                                           scale: Float(geometry.model.scale), model: geometry.model)
        entityResources[name] = resources
        return resources
    }

    private func entityPartMatrices(_ entity: Entity, model: MobModel,
                                    partial: Double) -> [ABIMat4] {
        let living = entity as? LivingEntity
        let swing = living?.limbSwing ?? 0
        let amplitude = living?.limbAmp ?? 0
        let walkA = detCos(swing * 0.6662) * 1.2 * amplitude
        let walkB = detCos(swing * 0.6662 + .pi) * 1.2 * amplitude
        let headYaw = living.map { wrappedAngle($0.headYaw - entity.yaw) } ?? 0
        let attack = living?.attackAnim ?? 0
        var matrices = [ABIMat4](repeating: .identity, count: 24)
        for index in 0..<min(24, model.parts.count) {
            let part = model.parts[index]
            var matrix = mat4Identity()
            matrix = mat4Translate(matrix, Float(part.pivot.0 / 16), Float(part.pivot.1 / 16),
                                   Float(part.pivot.2 / 16))
            if part.rot.2 != 0 { matrix = mat4RotateZ(matrix, Float(part.rot.2)) }
            if part.rot.1 != 0 { matrix = mat4RotateY(matrix, Float(part.rot.1)) }
            if part.rot.0 != 0 { matrix = mat4RotateX(matrix, Float(part.rot.0)) }
            let name = part.name
            switch model.anim {
            case "biped", "zombie", "skeleton", "illager", "villager", "fly_biped":
                if name == "head" {
                    matrix = mat4RotateY(matrix, Float(headYaw))
                    matrix = mat4RotateX(matrix, Float(-entity.pitch))
                } else if name == "armR" {
                    var rotation = walkA * 0.8
                    if model.anim == "zombie" { rotation = .pi / 2 }
                    if attack > 0 { rotation += detSin(attack * .pi) * 1.2 }
                    matrix = mat4RotateX(matrix, Float(rotation))
                } else if name == "armL" {
                    matrix = mat4RotateX(matrix, Float(model.anim == "zombie" ? .pi / 2 : walkB * 0.8))
                } else if name == "legR" {
                    matrix = mat4RotateX(matrix, Float(walkA))
                } else if name == "legL" {
                    matrix = mat4RotateX(matrix, Float(walkB))
                } else if name == "wingR" || name == "wingL" {
                    let flap = detSin((Double(entity.age) + partial) * 0.9) * 0.8
                    matrix = mat4RotateY(matrix, Float(name == "wingR" ? flap : -flap))
                }
            case "quadruped", "pig", "cow", "sheep", "wolf", "goat", "horse":
                if name == "head" { matrix = mat4RotateX(matrix, Float(-entity.pitch)) }
                else if name.contains("leg") {
                    let alternate = name.hasSuffix("R") || name.contains("FR") || name.contains("BL")
                    matrix = mat4RotateX(matrix, Float(alternate ? walkA : walkB))
                }
            case "bird", "chicken", "parrot", "bee":
                if name.contains("wing") {
                    let flap = detSin((Double(entity.age) + partial) * 1.8) * 0.9
                    matrix = mat4RotateZ(matrix, Float(name.hasSuffix("R") ? flap : -flap))
                }
            case "fish", "squid":
                if name.contains("tail") || name.contains("tentacle") {
                    matrix = mat4RotateY(matrix, Float(detSin((Double(entity.age) + partial) * 0.35) * 0.35))
                }
            default: break
            }
            matrices[index] = abi(matrix)
        }
        return matrices
    }

    private func appendViewmodel(game: GameCore, direction: SIMD3<Float>, right: SIMD3<Float>,
                                 up: SIMD3<Float>, uniforms: FrameUniforms, partial: Double,
                                 builder: inout FrameBuilder) {
        guard game.perspective == 0, !screenOpen, let player = game.player,
              player.deathTime == 0, !player.dead,
              let resources = viewmodelResources() else { return }
        let swing = Float(detSin((player.attackAnim + partial * 0.05) * .pi))
        let position = direction * (0.62 - swing * 0.08) + right * (0.43 - swing * 0.12) -
                       up * (0.45 + swing * 0.08)
        var model = mat4Identity()
        model = mat4Translate(model, position.x, position.y, position.z)
        model = mat4RotateY(model, Float(.pi - player.yaw))
        model = mat4RotateX(model, Float(-player.pitch * 0.2 - Double(swing) * 0.7))
        model = mat4Scale(model, 0.82, 0.82, 0.82)
        let constants = EntityDrawPacketConstants(
            model: abi(model),
            light: SIMD4<Float>(15, 15, uniforms.dayLight, uniforms.gamma),
            misc: SIMD4<Float>(1, 1, 1_000_000, 1_000_001),
            overlay: SIMD4<Float>(1, 0.2, 0.2, player.invulnTicks > 0 ? 0.25 : 0),
            fogColor: uniforms.fogColor)
        var parts = [ABIMat4](repeating: .identity, count: 24)
        if let arm = resources.model.parts.first {
            var part = mat4Identity()
            part = mat4Translate(part, Float(arm.pivot.0 / 16), Float(arm.pivot.1 / 16), Float(arm.pivot.2 / 16))
            part = mat4RotateX(part, Float(-0.35 - Double(swing) * 0.8))
            parts[0] = abi(part)
        }
        var packet = RenderBytes.copy(constants)
        packet.append(contentsOf: RenderBytes.copy(parts))
        builder.addDraw(pass: .entities, pipeline: .entityHDR, mesh: resources.mesh,
                        depthBucket: UInt32.max, vertexRange: 0..<resources.vertexCount,
                        textures: [TextureBinding(index: 0, texture: resources.texture, sampler: nil)],
                        pushConstants: packet)
    }

    private func viewmodelResources() -> WinEntityResources? {
        let key = "__viewmodel_arm"
        if let cached = entityResources[key] { return cached }
        let base = getModel("player")
        guard let arm = base.parts.first(where: { $0.name == "armR" }) else { return nil }
        let model = MobModel(texW: base.texW, texH: base.texH, parts: [arm], anim: "viewmodel",
                             scale: base.scale, paint: base.paint, packTex: base.packTex,
                             packTexStack: base.packTexStack, packTexTints: base.packTexTints)
        let geometry = buildEntityGeometry(from: model, skinName: "player")
        guard let mesh = try? renderer.createMesh(RenderMeshData(
            vertexLayout: .entity, vertexBytes: geometry.verts.withUnsafeBytes { Array($0) })) else { return nil }
        let packed = resourcePacks.playerSkin(customURL: customSkinURL)
        let width = packed?.width ?? geometry.skin.w
        let height = packed?.height ?? geometry.skin.h
        let pixels = packed?.pixels ?? geometry.skin.data
        guard let texture = try? renderer.createTexture(RenderTextureData(
            width: width, height: height, format: .rgba8Unorm, bytes: pixels)) else {
            renderer.destroyMesh(mesh)
            return nil
        }
        let resources = WinEntityResources(mesh: mesh, texture: texture,
                                           vertexCount: UInt32(geometry.vertexCount),
                                           scale: Float(model.scale), model: model)
        entityResources[key] = resources
        return resources
    }

    private func entityModelName(_ entity: Entity) -> String? {
        if hasModel(entity.type) { return entity.type }
        switch entity.type {
        case "arrow", "trident": return "arrow_model"
        case "end_crystal": return "end_crystal_model"
        case "boat": return "boat_model"
        case "minecart": return "minecart_model"
        default: return nil
        }
    }

    private func wrappedAngle(_ angle: Double) -> Double {
        var value = angle
        while value > .pi { value -= .pi * 2 }
        while value < -.pi { value += .pi * 2 }
        return value
    }

    private func appendParticles(game: GameCore, cameraPosition: SIMD3<Double>, viewProjection: ABIMat4,
                                 right: SIMD3<Float>, up: SIMD3<Float>, dayLight: Float,
                                 timeSec: Double, builder: inout FrameBuilder) {
        let elapsed = min(0.1, max(0, timeSec - (particleClock ?? timeSec)))
        particleClock = timeSec
        if elapsed > 0 {
            for index in particles.indices {
                particles[index].age += elapsed
                particles[index].velocity.y -= particles[index].gravity * elapsed * 20
                let drag = pow(0.98, elapsed * 20)
                particles[index].velocity *= drag
                particles[index].position += particles[index].velocity * (elapsed * 20)
            }
            particles.removeAll { $0.age >= $0.lifetime }
        }
        let corners: [Float] = [-1, -1, 1, -1, 1, 1, -1, -1, 1, 1, -1, 1]
        var instances: [ParticleInstance] = []
        instances.reserveCapacity(particles.count + 128)
        for particle in particles {
            let lifeScale = particle.shrink ? max(0.2, 1 - particle.age / particle.lifetime) : 1
            let encoded = Double(particle.tile * 256) + min(255, particle.size * lifeScale * 100)
            instances.append(ParticleInstance(
                x: Float(particle.position.x - cameraPosition.x),
                y: Float(particle.position.y - cameraPosition.y),
                z: Float(particle.position.z - cameraPosition.z),
                u0: 0, v0: 0, u1: 1, v1: 1, layerSize: Float(encoded),
                r: particle.color.x, g: particle.color.y, b: particle.color.z, light: particle.light))
        }
        appendEntitySprites(game: game, cameraPosition: cameraPosition, instances: &instances)
        guard !instances.isEmpty else { return }
        var bytes = corners.withUnsafeBytes { Array($0) }
        bytes.append(contentsOf: RenderBytes.copy(instances))
        let data = RenderMeshData(vertexLayout: .particle, vertexBytes: bytes)
        if let particleMesh {
            try? renderer.updateMesh(particleMesh, data: data)
        } else {
            particleMesh = try? renderer.createMesh(data)
        }
        guard let particleMesh else { return }
        let constants = ParticleUniforms(
            viewProj: viewProjection,
            right: SIMD4<Float>(right.x, right.y, right.z, 0),
            up: SIMD4<Float>(up.x, up.y, up.z, dayLight))
        builder.addDraw(pass: .particles, pipeline: .particle, mesh: particleMesh,
                        vertexRange: 0..<6, instanceRange: 0..<UInt32(instances.count),
                        textures: [TextureBinding(index: 3, texture: atlas, sampler: nil)],
                        pushConstants: RenderBytes.copy(constants))
    }

    private func appendEntitySprites(game: GameCore, cameraPosition: SIMD3<Double>,
                                     instances: inout [ParticleInstance]) {
        let spriteTypes: Set<String> = ["snowball", "egg", "ender_pearl", "xp_bottle",
            "thrown_potion", "firework", "eye_of_ender", "fishing_bobber", "wither_skull",
            "dragon_fireball", "fireball", "shulker_bullet", "llama_spit"]
        for reference in game.world.entities {
            guard let entity = reference as? Entity, !entity.dead,
                  entity.type == "item" || entity.type == "xp_orb" || spriteTypes.contains(entity.type) else { continue }
            let dx = entity.x - cameraPosition.x, dz = entity.z - cameraPosition.z
            if dx * dx + dz * dz > 64 * 64 { continue }
            var tile = tileId("crit_particle")
            var color = SIMD3<Float>(1, 1, 1)
            var size = 0.22
            var light: Float = 0.85
            if let item = entity as? ItemEntity {
                let definition = itemDef(item.stack.id)
                if let block = definition.block {
                    let blockDefinition = blockDefs[Int(block)]
                    if !blockDefinition.tex.isEmpty { tile = Int(blockDefinition.tex[min(2, blockDefinition.tex.count - 1)]) }
                } else {
                    let hash = hashString(definition.name)
                    color = SIMD3<Float>(0.45 + Float(hash & 255) / 510,
                                         0.45 + Float((hash >> 8) & 255) / 510,
                                         0.45 + Float((hash >> 16) & 255) / 510)
                }
                size = 0.24
            } else if entity.type == "xp_orb" {
                color = SIMD3<Float>(0.45, 1, 0.15); size = 0.18; light = 1
            } else if entity.type == "fireball" || entity.type == "dragon_fireball" || entity.type == "wither_skull" {
                tile = tileId("flame_particle"); size = 0.25; light = 1
            }
            let bob = entity.type == "item" ? detSin(Double(entity.age) * 0.08) * 0.08 + 0.18 : 0.12
            instances.append(ParticleInstance(
                x: Float(entity.x - cameraPosition.x),
                y: Float(entity.y + bob - cameraPosition.y),
                z: Float(entity.z - cameraPosition.z),
                u0: 0, v0: 0, u1: 1, v1: 1,
                layerSize: Float(tile * 256) + Float(size * 100),
                r: color.x, g: color.y, b: color.z, light: light))
        }
        for reference in game.world.entities {
            guard let entity = reference as? Entity, !entity.dead else { continue }
            if entity is LightningBolt {
                for segment in 0..<32 {
                    let jitter = Double(Int(hash2(UInt32(truncatingIfNeeded: entity.id), segment, entity.age / 2) % 100)) / 500 - 0.1
                    instances.append(ParticleInstance(
                        x: Float(entity.x + jitter - cameraPosition.x),
                        y: Float(entity.y + Double(segment) * 1.25 - cameraPosition.y),
                        z: Float(entity.z - jitter - cameraPosition.z),
                        u0: 0, v0: 0, u1: 1, v1: 1,
                        layerSize: Float(tileId("crit_particle") * 256 + 12),
                        r: 0.78, g: 0.88, b: 1, light: 1))
                }
            } else if let crystal = entity as? EndCrystal, let target = crystal.beamTarget {
                let start = SIMD3<Double>(crystal.x, crystal.y + 1, crystal.z)
                let end = SIMD3<Double>(Double(target.0) + 0.5, Double(target.1) + 0.5, Double(target.2) + 0.5)
                let delta = end - start
                let steps = max(2, min(96, Int(sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z) * 2)))
                for step in 0...steps {
                    let position = start + delta * (Double(step) / Double(steps))
                    instances.append(ParticleInstance(
                        x: Float(position.x - cameraPosition.x), y: Float(position.y - cameraPosition.y),
                        z: Float(position.z - cameraPosition.z), u0: 0, v0: 0, u1: 1, v1: 1,
                        layerSize: Float(tileId("portal_particle") * 256 + 9),
                        r: 0.95, g: 0.25, b: 1, light: 1))
                }
            }
        }
    }

    private func spawnParticles(_ type: String, x: Double, y: Double, z: Double,
                                count: Int, spread: Double, cell: Int = 0) {
        for _ in 0..<max(0, count) {
            if particles.count >= 4096 { particles.removeFirst() }
            let ox = (randomUnit() - 0.5) * spread * 2
            let oy = (randomUnit() - 0.5) * spread * 2
            let oz = (randomUnit() - 0.5) * spread * 2
            var tile = tileId("crit_particle")
            var color = SIMD3<Float>(1, 1, 1)
            var gravity = 0.04
            var lifetime = 1.2 + randomUnit()
            var size = 0.1 + randomUnit() * 0.05
            var velocity = SIMD3<Double>((randomUnit() - 0.5) * 0.08,
                                         randomUnit() * 0.1,
                                         (randomUnit() - 0.5) * 0.08)
            var light: Float = 1
            var shrink = true
            switch type {
            case "block":
                let id = cell >> 4
                if id > 0 && id < blockDefs.count {
                    let definition = blockDefs[id]
                    tile = definition.texFn?(cell & 15, 2) ?? (definition.tex.isEmpty ? tile : Int(definition.tex[2]))
                }
                velocity = SIMD3<Double>((randomUnit() - 0.5) * 0.2,
                                         randomUnit() * 0.18 + 0.05,
                                         (randomUnit() - 0.5) * 0.2)
                lifetime = 0.7 + randomUnit() * 0.8
            case "smoke", "campfire_smoke":
                tile = tileId("smoke_particle"); color = SIMD3<Float>(repeating: 0.35)
                gravity = -0.004; velocity.y = 0.04 + randomUnit() * 0.04
                lifetime = type == "campfire_smoke" ? 5 : 2; size = 0.17
            case "flame", "soul_flame":
                tile = tileId("flame_particle"); gravity = -0.002; lifetime = 1; size = 0.07
                if type == "soul_flame" { color = SIMD3<Float>(0.2, 0.85, 0.9) }
            case "heart": tile = tileId("heart_particle"); gravity = -0.002; lifetime = 1.2; size = 0.12
            case "portal", "dragon_breath":
                tile = tileId("portal_particle"); color = SIMD3<Float>(0.72, 0.2, 0.85); gravity = -0.005
            case "rain": tile = tileId("splash_particle"); velocity = SIMD3<Double>(0, -0.95, 0); gravity = 0; shrink = false
            case "snow": tile = tileId("snow_particle"); velocity.y = -0.07; gravity = 0; lifetime = 6; shrink = false
            case "explosion": tile = tileId("smoke_particle"); size = 0.7; lifetime = 0.8
            default: break
            }
            particles.append(WinParticle(position: SIMD3<Double>(x + ox, y + oy, z + oz),
                                         velocity: velocity, lifetime: lifetime, size: size,
                                         gravity: gravity, tile: tile, color: color,
                                         light: light, shrink: shrink))
        }
    }

    private func randomUnit() -> Double {
        particleRandom = particleRandom &* 1664525 &+ 1013904223
        return Double(particleRandom) / Double(UInt32.max)
    }

    private func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(a.y * b.z - a.z * b.y,
                     a.z * b.x - a.x * b.z,
                     a.x * b.y - a.y * b.x)
    }

    private func normalized(_ value: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
        return length > 0.0001 ? value / length : fallback
    }

    private func appendUI(game: GameCore, target: RenderTarget, builder: inout FrameBuilder) {
        let width = Float(target.width), height = Float(target.height)
        lastScreenSize = SIMD2<Float>(width, height)
        uiCanvas.begin(width: width, height: height)
        hoveredStack = nil
        if screenOpen {
            uiCanvas.fillRect(x: 0, y: 0, width: width, height: height,
                              color: SIMD4<Float>(0, 0, 0, 0.58))
            if screenKind == "chat" {
                uiCanvas.fillRect(x: 14, y: height - 58, width: width - 28, height: 40,
                                  color: SIMD4<Float>(0.03, 0.04, 0.06, 0.92))
                _ = uiCanvas.text("> " + textBuffer + "_", x: 24, y: height - 48, scale: 2,
                                  color: SIMD4<Float>(1, 1, 1, 1))
            } else if screenKind == "title" {
                appendTitleScreen(game: game, width: width, height: height)
            } else if screenKind == "create_world" {
                appendCreateWorldScreen(width: width, height: height)
            } else if screenKind == "multiplayer" {
                appendMultiplayerScreen(width: width, height: height)
            } else if screenKind == "options" {
                appendOptionsScreen(game: game, width: width, height: height)
            } else if screenKind == "trading" {
                appendTradingScreen(game: game, width: width, height: height)
            } else if screenKind == "sign" {
                appendSignScreen(width: width, height: height)
            } else if screenKind == "pause" || screenKind == "death" {
                appendActionScreen(game: game, width: width, height: height)
            } else if screenKind == "crafting" {
                appendCraftingScreen(game: game, width: width, height: height)
            } else if screenKind == "enchanting" {
                appendEnchantingScreen(game: game, width: width, height: height)
            } else if screenKind == "anvil" {
                appendAnvilScreen(game: game, width: width, height: height)
            } else if screenKind == "grindstone" {
                appendGrindstoneScreen(game: game, width: width, height: height)
            } else if screenKind == "stonecutter" {
                appendStonecutterScreen(game: game, width: width, height: height)
            } else if screenKind == "smithing" {
                appendSmithingScreen(game: game, width: width, height: height)
            } else if screenKind == "beacon" {
                appendBeaconScreen(game: game, width: width, height: height)
            } else if screenKind == "creative" {
                appendCreativeScreen(game: game, width: width, height: height)
            } else if screenKind == "inventory" {
                appendInventoryScreen(game: game, width: width, height: height)
            } else if screenData?.be?.items != nil {
                appendContainerScreen(game: game, width: width, height: height)
            } else {
                uiCanvas.textCentered(screenKind == "pause" ? "GAME PAUSED" : screenKind.uppercased(),
                                      centerX: width / 2, y: height / 2 - 36,
                                      scale: 4, color: SIMD4<Float>(1, 1, 1, 1))
                uiCanvas.textCentered("PRESS ESCAPE TO RESUME", centerX: width / 2, y: height / 2 + 20,
                                      scale: 2, color: SIMD4<Float>(0.75, 0.78, 0.82, 1))
            }
        } else if game.hasWorld() {
            uiCanvas.fillRect(x: width / 2 - 1, y: height / 2 - 7, width: 2, height: 14,
                              color: SIMD4<Float>(1, 1, 1, 0.9))
            uiCanvas.fillRect(x: width / 2 - 7, y: height / 2 - 1, width: 14, height: 2,
                              color: SIMD4<Float>(1, 1, 1, 0.9))
            let worldName = game.worldRec?.name ?? "WORLD"
            _ = uiCanvas.text(worldName, x: 12, y: 12, scale: 2,
                              color: SIMD4<Float>(1, 1, 1, 0.92))
            _ = uiCanvas.text("X \(Int(game.player.x)) Y \(Int(game.player.y)) Z \(Int(game.player.z))",
                              x: 12, y: 34, scale: 1.5,
                              color: SIMD4<Float>(0.8, 0.85, 0.9, 0.9))
            appendSurvivalHUD(game: game, width: width, height: height)
            appendSubtitles(width: width, height: height)
        }
        if screenOpen, carriedStack == nil, let hoveredStack {
            appendItemTooltip(hoveredStack, width: width, height: height)
        }
        let batch = uiCanvas.finish()
        guard !batch.vertices.isEmpty else { return }
        if let uiMesh {
            try? renderer.updateMesh(uiMesh, data: batch.meshData)
        } else {
            uiMesh = try? renderer.createMesh(batch.meshData)
        }
        guard let uiMesh else { return }
        builder.addDraw(pass: .ui, pipeline: .ui, mesh: uiMesh,
                        vertexRange: 0..<UInt32(batch.vertices.count))
    }

    private func appendSignScreen(width: Float, height: Float) {
        let panelWidth: Float = 420, panelHeight: Float = 260
        let x = (width - panelWidth) / 2, y = (height - panelHeight) / 2
        uiCanvas.fillRect(x: x, y: y, width: panelWidth, height: panelHeight,
                          color: SIMD4<Float>(0.34, 0.22, 0.1, 0.98))
        uiCanvas.textCentered("EDIT SIGN", centerX: width / 2, y: y + 20, scale: 2)
        let lines = screenData?.be?.lines ?? ["", "", "", ""]
        for index in 0..<4 {
            let lineY = y + 72 + Float(index) * 34
            if index == signLine {
                uiCanvas.fillRect(x: x + 28, y: lineY - 6, width: panelWidth - 56, height: 26,
                                  color: SIMD4<Float>(0.12, 0.08, 0.04, 0.45))
            }
            uiCanvas.textCentered((index < lines.count ? lines[index] : "") + (index == signLine ? "_" : ""),
                                  centerX: width / 2, y: lineY, scale: 1.8,
                                  color: SIMD4<Float>(0.08, 0.055, 0.025, 1))
        }
        uiCanvas.textCentered("ENTER: NEXT LINE   ESC: DONE", centerX: width / 2,
                              y: y + panelHeight - 28, scale: 1.1,
                              color: SIMD4<Float>(0.85, 0.75, 0.58, 1))
    }

    private func appendTradingScreen(game: GameCore, width: Float, height: Float) {
        let offers = currentTradeOffers()
        let panelWidth: Float = 470
        let panelHeight = min(height - 40, Float(max(1, offers.count)) * 46 + 82)
        let x = (width - panelWidth) / 2
        let y = (height - panelHeight) / 2
        uiCanvas.fillRect(x: x, y: y, width: panelWidth, height: panelHeight,
                          color: SIMD4<Float>(0.1, 0.11, 0.14, 0.98))
        let profession = (tradingMob as? Villager)?.profession ?? "wandering trader"
        _ = uiCanvas.text("TRADING - \(profession.uppercased())", x: x + 16, y: y + 14, scale: 1.7)
        for (index, offer) in offers.prefix(8).enumerated() {
            let rowY = y + 48 + Float(index) * 46
            let hovered = screenMousePosition.x >= x + 14 && screenMousePosition.x < x + panelWidth - 14 &&
                          screenMousePosition.y >= rowY && screenMousePosition.y < rowY + 38
            let exhausted = offer.uses >= offer.maxUses
            uiCanvas.fillRect(x: x + 14, y: rowY, width: panelWidth - 28, height: 38,
                              color: exhausted ? SIMD4<Float>(0.28, 0.08, 0.08, 0.9)
                                  : hovered ? SIMD4<Float>(0.25, 0.34, 0.28, 1)
                                            : SIMD4<Float>(0.16, 0.18, 0.21, 1))
            let first = "\(offer.buyA.count) \(itemName(offer.buyA.id).uppercased())"
            let second = offer.buyB.map { " + \($0.count) \(itemName($0.id).uppercased())" } ?? ""
            let result = "\(offer.sell.count) \(itemName(offer.sell.id).uppercased())"
            _ = uiCanvas.text(first + second, x: x + 24, y: rowY + 12, scale: 1.15,
                              color: SIMD4<Float>(0.82, 0.88, 0.82, 1))
            _ = uiCanvas.text("-> " + result, x: x + 272, y: rowY + 12, scale: 1.15,
                              color: SIMD4<Float>(0.95, 0.86, 0.42, 1))
        }
    }

    private func appendOptionsScreen(game: GameCore, width: Float, height: Float) {
        uiCanvas.textCentered("OPTIONS", centerX: width / 2, y: height * 0.18, scale: 4)
        let x = width / 2 - 190
        let y = height * 0.27
        let rows = [
            "RENDER DISTANCE  \(game.settings.renderDistance)",
            "FIELD OF VIEW  \(game.settings.fov)",
            "ENTITY DISTANCE  \(Int(game.settings.entityDistance))",
            "SHADOWS  \(game.settings.shadows ? "ON" : "OFF")",
            "CLOUDS  \(game.settings.clouds ? "ON" : "OFF")",
            "PARTICLES  \(["MINIMAL", "DECREASED", "ALL"][max(0, min(2, game.settings.particles))])",
            "ULTRA GRAPHICS  \(game.settings.shader == "ultra" ? "ON" : "OFF")",
            "BRIGHTNESS  \(Int(game.settings.gamma * 100))%",
            "VIEW BOBBING  \(game.settings.viewBobbing ? "ON" : "OFF")",
            "SENSITIVITY  \(Int(game.settings.sensitivity * 100))%",
            "INVERT Y  \(game.settings.invertY ? "ON" : "OFF")",
            "AUTO JUMP  \(game.settings.autoJump ? "ON" : "OFF")",
            "SUBTITLES  \(game.settings.subtitles ? "ON" : "OFF")",
            "MASTER VOLUME  \(Int((game.settings.volumes["master"] ?? 0.8) * 100))%",
            "MUSIC VOLUME  \(Int((game.settings.volumes["music"] ?? 0.5) * 100))%",
        ]
        for (index, title) in rows.enumerated() {
            actionButton(title, x: x, y: y + Float(index) * 36, width: 380)
        }
        actionButton("DONE", x: x, y: y + Float(rows.count) * 36, width: 380)
    }

    private func appendTitleScreen(game: GameCore, width: Float, height: Float) {
        uiCanvas.gradientRect(x: 0, y: 0, width: width, height: height,
                              top: SIMD4<Float>(0.035, 0.07, 0.13, 1),
                              bottom: SIMD4<Float>(0.12, 0.2, 0.18, 1))
        uiCanvas.textCentered("PEBBLE", centerX: width / 2, y: height * 0.2,
                              scale: 8, color: SIMD4<Float>(0.85, 0.94, 1, 1))
        uiCanvas.textCentered("A BLOCK SURVIVAL WORLD", centerX: width / 2, y: height * 0.2 + 70,
                              scale: 1.8, color: SIMD4<Float>(0.68, 0.76, 0.82, 1))
        let worlds = game.listWorlds()
        let listX = width / 2 - 280, listY = height * 0.39
        let rowHeight: Float = 42
        titleWorldSelection = min(max(0, titleWorldSelection), max(0, worlds.count - 1))
        titleWorldOffset = min(max(0, titleWorldOffset), max(0, worlds.count - 5))
        if titleWorldSelection < titleWorldOffset { titleWorldOffset = titleWorldSelection }
        if titleWorldSelection >= titleWorldOffset + 5 { titleWorldOffset = titleWorldSelection - 4 }
        uiCanvas.fillRect(x: listX, y: listY, width: 560, height: rowHeight * 5,
                          color: SIMD4<Float>(0.025, 0.035, 0.05, 0.9))
        if worlds.isEmpty {
            uiCanvas.textCentered("NO SAVED WORLDS", centerX: width / 2,
                                  y: listY + rowHeight * 2.2, scale: 1.8,
                                  color: SIMD4<Float>(0.65, 0.7, 0.76, 1))
        } else {
            for (visibleRow, worldIndex) in (titleWorldOffset..<min(worlds.count, titleWorldOffset + 5)).enumerated() {
                let world = worlds[worldIndex]
                let y = listY + Float(visibleRow) * rowHeight
                let hovered = screenMousePosition.x >= listX && screenMousePosition.x < listX + 560 &&
                              screenMousePosition.y >= y && screenMousePosition.y < y + rowHeight - 2
                let selected = worldIndex == titleWorldSelection
                uiCanvas.fillRect(x: listX + 2, y: y + 2, width: 556, height: rowHeight - 4,
                                  color: selected ? SIMD4<Float>(0.22, 0.35, 0.45, 1)
                                      : hovered ? SIMD4<Float>(0.16, 0.22, 0.28, 1)
                                                : SIMD4<Float>(0.08, 0.1, 0.13, 1))
                _ = uiCanvas.text(world.name, x: listX + 14, y: y + 8, scale: 1.7)
                let mode = world.gameMode == 1 ? "CREATIVE" : "SURVIVAL"
                _ = uiCanvas.text("\(mode)  SEED \(world.seed)", x: listX + 320, y: y + 12,
                                  scale: 1.05, color: SIMD4<Float>(0.7, 0.76, 0.8, 1))
            }
        }
        let buttonY = listY + rowHeight * 5 + 12
        let selectedID = worlds.isEmpty ? nil : worlds[titleWorldSelection].id
        actionButton(worlds.isEmpty ? "CREATE WORLD" : "PLAY SELECTED",
                     x: listX, y: buttonY, width: 274)
        let deleteTitle = selectedID != nil && pendingWorldDeleteID == selectedID
            ? "CONFIRM DELETE" : "DELETE WORLD"
        actionButton(deleteTitle, x: listX + 286, y: buttonY, width: 274)
        actionButton("NEW WORLD", x: listX, y: buttonY + 46, width: 274)
        actionButton("MULTIPLAYER", x: listX + 286, y: buttonY + 46, width: 274)
        actionButton("OPTIONS", x: listX, y: buttonY + 92, width: 274)
        actionButton("QUIT", x: listX + 286, y: buttonY + 92, width: 274)
        if worlds.count > 5 {
            uiCanvas.textCentered("MOUSE WHEEL OR ARROW KEYS TO BROWSE", centerX: width / 2,
                                  y: buttonY + 136, scale: 1,
                                  color: SIMD4<Float>(0.58, 0.65, 0.7, 1))
        }
        uiCanvas.textCentered("SDL3 + VULKAN", centerX: width / 2, y: height - 34,
                              scale: 1.2, color: SIMD4<Float>(0.55, 0.62, 0.68, 1))
    }

    private func appendCreateWorldScreen(width: Float, height: Float) {
        uiCanvas.gradientRect(x: 0, y: 0, width: width, height: height,
                              top: SIMD4<Float>(0.035, 0.07, 0.13, 1),
                              bottom: SIMD4<Float>(0.12, 0.2, 0.18, 1))
        let panelWidth: Float = 520, panelHeight: Float = 350
        let x = (width - panelWidth) / 2, y = (height - panelHeight) / 2
        uiCanvas.fillRect(x: x, y: y, width: panelWidth, height: panelHeight,
                          color: SIMD4<Float>(0.04, 0.055, 0.075, 0.96))
        uiCanvas.textCentered("CREATE NEW WORLD", centerX: width / 2, y: y + 28, scale: 2.8)
        _ = uiCanvas.text("WORLD NAME", x: x + 48, y: y + 90, scale: 1.3,
                          color: SIMD4<Float>(0.7, 0.78, 0.84, 1))
        textField(createWorldName + (createWorldField == 0 ? "_" : ""),
                  x: x + 48, y: y + 112, width: panelWidth - 96, focused: createWorldField == 0)
        _ = uiCanvas.text("SEED (BLANK FOR RANDOM)", x: x + 48, y: y + 166, scale: 1.3,
                          color: SIMD4<Float>(0.7, 0.78, 0.84, 1))
        textField(createWorldSeed + (createWorldField == 1 ? "_" : ""),
                  x: x + 48, y: y + 188, width: panelWidth - 96, focused: createWorldField == 1)
        actionButton(createWorldMode == 1 ? "MODE: CREATIVE" : "MODE: SURVIVAL",
                     x: x + 48, y: y + 240, width: panelWidth - 96)
        actionButton("CREATE WORLD", x: x + 48, y: y + 292, width: 202)
        actionButton("CANCEL", x: x + 270, y: y + 292, width: 202)
    }

    private func textField(_ value: String, x: Float, y: Float, width: Float, focused: Bool) {
        uiCanvas.fillRect(x: x, y: y, width: width, height: 36,
                          color: focused ? SIMD4<Float>(0.28, 0.38, 0.48, 1)
                                         : SIMD4<Float>(0.12, 0.15, 0.19, 1))
        uiCanvas.fillRect(x: x + 2, y: y + 2, width: width - 4, height: 32,
                          color: SIMD4<Float>(0.025, 0.03, 0.04, 1))
        _ = uiCanvas.text(String(value.suffix(34)), x: x + 10, y: y + 11, scale: 1.4)
    }

    private func appendMultiplayerScreen(width: Float, height: Float) {
        uiCanvas.gradientRect(x: 0, y: 0, width: width, height: height,
                              top: SIMD4<Float>(0.035, 0.07, 0.13, 1),
                              bottom: SIMD4<Float>(0.12, 0.2, 0.18, 1))
        let panelWidth: Float = 520, panelHeight: Float = 350
        let x = (width - panelWidth) / 2, y = (height - panelHeight) / 2
        uiCanvas.fillRect(x: x, y: y, width: panelWidth, height: panelHeight,
                          color: SIMD4<Float>(0.04, 0.055, 0.075, 0.96))
        uiCanvas.textCentered("DIRECT CONNECTION", centerX: width / 2, y: y + 28, scale: 2.8)
        _ = uiCanvas.text("SERVER ADDRESS", x: x + 48, y: y + 90, scale: 1.3,
                          color: SIMD4<Float>(0.7, 0.78, 0.84, 1))
        textField(multiplayerAddress + (multiplayerField == 0 ? "_" : ""),
                  x: x + 48, y: y + 112, width: panelWidth - 96, focused: multiplayerField == 0)
        _ = uiCanvas.text("PLAYER NAME", x: x + 48, y: y + 166, scale: 1.3,
                          color: SIMD4<Float>(0.7, 0.78, 0.84, 1))
        textField(multiplayerName + (multiplayerField == 1 ? "_" : ""),
                  x: x + 48, y: y + 188, width: panelWidth - 96, focused: multiplayerField == 1)
        if !multiplayerMessage.isEmpty {
            uiCanvas.textCentered(multiplayerMessage, centerX: width / 2, y: y + 244, scale: 1.15,
                                  color: SIMD4<Float>(1, 0.45, 0.4, 1))
        }
        actionButton("CONNECT", x: x + 48, y: y + 292, width: 202)
        actionButton("CANCEL", x: x + 270, y: y + 292, width: 202)
    }

    private func appendActionScreen(game: GameCore, width: Float, height: Float) {
        let centerX = width / 2
        if screenKind == "death" {
            uiCanvas.textCentered("YOU DIED", centerX: centerX, y: height / 2 - 92,
                                  scale: 4, color: SIMD4<Float>(1, 0.25, 0.25, 1))
            uiCanvas.textCentered(screenMessage, centerX: centerX, y: height / 2 - 52,
                                  scale: 1.4, color: SIMD4<Float>(0.9, 0.9, 0.92, 1))
            actionButton("RESPAWN", x: centerX - 130, y: height / 2, width: 260)
            actionButton("SAVE AND QUIT", x: centerX - 130, y: height / 2 + 48, width: 260)
        } else {
            uiCanvas.textCentered("GAME PAUSED", centerX: centerX, y: height / 2 - 112, scale: 3)
            actionButton("BACK TO GAME", x: centerX - 130, y: height / 2 - 54, width: 260)
            let lanTitle = game.netHost != nil ? "LAN OPEN" : game.netGuest != nil ? "CONNECTED" : "OPEN TO LAN"
            actionButton(lanTitle, x: centerX - 130, y: height / 2 - 6, width: 260)
            actionButton("OPTIONS", x: centerX - 130, y: height / 2 + 42, width: 260)
            actionButton("SAVE AND QUIT", x: centerX - 130, y: height / 2 + 90, width: 260)
        }
    }

    private func actionButton(_ title: String, x: Float, y: Float, width: Float) {
        let hovered = screenMousePosition.x >= x && screenMousePosition.x < x + width &&
                      screenMousePosition.y >= y && screenMousePosition.y < y + 34
        uiCanvas.fillRect(x: x, y: y, width: width, height: 34,
                          color: hovered ? SIMD4<Float>(0.35, 0.42, 0.58, 0.96)
                                         : SIMD4<Float>(0.16, 0.18, 0.23, 0.96))
        uiCanvas.textCentered(title, centerX: x + width / 2, y: y + 10, scale: 1.5)
    }

    private func appendContainerScreen(game: GameCore, width: Float, height: Float) {
        guard let blockEntity = screenData?.be, let items = blockEntity.items else { return }
        let secondItems = screenData?.other?.items ?? []
        let containerCount = items.count + secondItems.count
        let rows = max(1, (containerCount + 8) / 9)
        let slot: Float = 42
        let panelWidth = slot * 9 + 28
        let panelHeight = Float(rows + 4) * slot + 74
        let panelX = (width - panelWidth) / 2
        let panelY = max(12, (height - panelHeight) / 2)
        uiCanvas.fillRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight,
                          color: SIMD4<Float>(0.1, 0.11, 0.14, 0.98))
        _ = uiCanvas.text(screenData?.title ?? screenKind.uppercased(),
                          x: panelX + 14, y: panelY + 12, scale: 1.7)
        let gridX = panelX + 14
        let containerY = panelY + 42
        for index in 0..<containerCount {
            let stack = index < items.count ? items[index] : secondItems[index - items.count]
            inventorySlot(stack, x: gridX + Float(index % 9) * slot,
                          y: containerY + Float(index / 9) * slot, selected: false)
        }
        let playerY = containerY + Float(rows) * slot + 18
        if let player = game.player {
            for row in 0..<3 {
                for column in 0..<9 {
                    let index = 9 + row * 9 + column
                    inventorySlot(player.inventory[index], x: gridX + Float(column) * slot,
                                  y: playerY + Float(row) * slot, selected: false)
                }
            }
            for column in 0..<9 {
                inventorySlot(player.inventory[column], x: gridX + Float(column) * slot,
                              y: playerY + 3 * slot + 10,
                              selected: column == player.selectedSlot)
            }
        }
        if blockEntity.type == "furnace" {
            let progress = Float(blockEntity.cookTime ?? 0) / Float(max(1, blockEntity.cookTotal ?? 200))
            meter(x: panelX + 14, y: panelY + panelHeight - 12, width: panelWidth - 28,
                  ratio: progress, fill: SIMD4<Float>(1, 0.55, 0.15, 1), label: "")
        } else if blockEntity.type == "brewing" {
            let progress = 1 - Float(blockEntity.brewTime ?? 0) / 400
            meter(x: panelX + 14, y: panelY + panelHeight - 12, width: panelWidth - 28,
                  ratio: progress, fill: SIMD4<Float>(0.65, 0.25, 0.9, 1), label: "")
        }
        if let carriedStack { inventoryItem(carriedStack, x: screenMousePosition.x + 6, y: screenMousePosition.y + 6) }
    }

    private func appendInventoryScreen(game: GameCore, width: Float, height: Float) {
        guard let player = game.player else { return }
        let slot: Float = 42
        let panelWidth = slot * 9 + 28
        let panelHeight: Float = 392
        let panelX = (width - panelWidth) / 2
        let panelY = (height - panelHeight) / 2
        uiCanvas.fillRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight,
                          color: SIMD4<Float>(0.1, 0.11, 0.14, 0.97))
        _ = uiCanvas.text(screenKind == "creative" ? "CREATIVE INVENTORY" : "INVENTORY",
                          x: panelX + 14, y: panelY + 12, scale: 1.8)
        for armorSlot in 0..<4 {
            inventorySlot(player.armor[armorSlot], x: panelX + 14,
                          y: panelY + 46 + Float(armorSlot) * slot, selected: false)
        }
        inventorySlot(player.offHand, x: panelX + 70, y: panelY + 88, selected: false)
        let craftX = panelX + 158, craftY = panelY + 58
        for index in 0..<4 {
            inventorySlot(inventoryCraftingGrid[index],
                          x: craftX + Float(index % 2) * slot,
                          y: craftY + Float(index / 2) * slot, selected: false)
        }
        _ = uiCanvas.text("->", x: panelX + 252, y: panelY + 84, scale: 2.4,
                          color: SIMD4<Float>(0.7, 0.74, 0.78, 1))
        inventorySlot(matchCrafting(inventoryCraftingGrid, 2, 2)?.out,
                      x: panelX + 308, y: panelY + 80, selected: true)
        let gridX = panelX + 14
        let mainY = panelY + 220
        for row in 0..<3 {
            for column in 0..<9 {
                let inventoryIndex = 9 + row * 9 + column
                inventorySlot(player.inventory[inventoryIndex], x: gridX + Float(column) * slot,
                              y: mainY + Float(row) * slot, selected: false)
            }
        }
        let hotbarY = mainY + 3 * slot + 10
        for column in 0..<9 {
            inventorySlot(player.inventory[column], x: gridX + Float(column) * slot,
                          y: hotbarY, selected: column == player.selectedSlot)
        }
        if let carriedStack {
            inventoryItem(carriedStack, x: screenMousePosition.x + 6, y: screenMousePosition.y + 6)
        }
    }

    private var creativeItemIDs: [Int] {
        let query = creativeSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return itemDefs.indices.filter {
            itemName($0) != "air" && (query.isEmpty || itemName($0).contains(query) ||
                                      itemDef($0).displayName.lowercased().contains(query))
        }
    }

    private func appendCreativeScreen(game: GameCore, width: Float, height: Float) {
        guard let player = game.player else { return }
        let slot: Float = 42, panelWidth = slot * 9 + 28, panelHeight: Float = 310
        let panelX = (width - panelWidth) / 2, panelY = (height - panelHeight) / 2
        uiCanvas.fillRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight,
                          color: SIMD4<Float>(0.09, 0.1, 0.12, 0.98))
        _ = uiCanvas.text("CREATIVE INVENTORY", x: panelX + 14, y: panelY + 14, scale: 1.8)
        textField(creativeSearch.isEmpty ? "SEARCH_" : creativeSearch + "_",
                  x: panelX + 212, y: panelY + 8, width: 180, focused: true)
        let ids = creativeItemIDs
        let maxRow = max(0, (ids.count + 8) / 9 - 4)
        creativeScrollRow = min(max(0, creativeScrollRow), maxRow)
        let gridX = panelX + 14, gridY = panelY + 46
        for visible in 0..<36 {
            let source = (creativeScrollRow * 9) + visible
            let x = gridX + Float(visible % 9) * slot, y = gridY + Float(visible / 9) * slot
            let stack = source < ids.count ? ItemStack(ids[source], itemDef(ids[source]).maxStack) : nil
            inventorySlot(stack, x: x, y: y, selected: false)
        }
        _ = uiCanvas.text("ALL ITEMS  ROW \(creativeScrollRow + 1)/\(maxRow + 1)",
                          x: panelX + 14, y: panelY + 220, scale: 1.05,
                          color: SIMD4<Float>(0.65, 0.7, 0.75, 1))
        let hotbarY = panelY + 248
        for column in 0..<9 {
            inventorySlot(player.inventory[column], x: gridX + Float(column) * slot,
                          y: hotbarY, selected: column == player.selectedSlot)
        }
        if let carriedStack { inventoryItem(carriedStack, x: screenMousePosition.x + 6, y: screenMousePosition.y + 6) }
    }

    private func appendCraftingScreen(game: GameCore, width: Float, height: Float) {
        guard let player = game.player else { return }
        let slot: Float = 42
        let panelWidth = slot * 9 + 28, panelHeight: Float = 392
        let panelX = (width - panelWidth) / 2, panelY = (height - panelHeight) / 2
        uiCanvas.fillRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight,
                          color: SIMD4<Float>(0.1, 0.11, 0.14, 0.98))
        _ = uiCanvas.text("CRAFTING", x: panelX + 14, y: panelY + 14, scale: 1.8)
        let craftX = panelX + 42, craftY = panelY + 48
        for index in 0..<9 {
            inventorySlot(craftingGrid[index], x: craftX + Float(index % 3) * slot,
                          y: craftY + Float(index / 3) * slot, selected: false)
        }
        _ = uiCanvas.text("->", x: panelX + 190, y: panelY + 92, scale: 2.4,
                          color: SIMD4<Float>(0.7, 0.74, 0.78, 1))
        inventorySlot(matchCrafting(craftingGrid, 3, 3)?.out,
                      x: panelX + 262, y: panelY + 90, selected: true)
        let inventoryY = panelY + 220
        for row in 0..<3 {
            for column in 0..<9 {
                let index = 9 + row * 9 + column
                inventorySlot(player.inventory[index], x: panelX + 14 + Float(column) * slot,
                              y: inventoryY + Float(row) * slot, selected: false)
            }
        }
        for column in 0..<9 {
            inventorySlot(player.inventory[column], x: panelX + 14 + Float(column) * slot,
                          y: inventoryY + 3 * slot + 10, selected: column == player.selectedSlot)
        }
        if let carriedStack { inventoryItem(carriedStack, x: screenMousePosition.x + 6, y: screenMousePosition.y + 6) }
    }

    private func appendEnchantingScreen(game: GameCore, width: Float, height: Float) {
        guard let player = game.player else { return }
        let slot: Float = 42
        let panelWidth = slot * 9 + 28, panelHeight: Float = 392
        let panelX = (width - panelWidth) / 2, panelY = (height - panelHeight) / 2
        uiCanvas.fillRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight,
                          color: SIMD4<Float>(0.1, 0.08, 0.15, 0.98))
        _ = uiCanvas.text("ENCHANTING", x: panelX + 14, y: panelY + 14, scale: 1.8)
        inventorySlot(enchantingItem, x: panelX + 28, y: panelY + 66, selected: true)
        inventorySlot(enchantingLapis, x: panelX + 28, y: panelY + 116, selected: false)
        let options = enchantingOptions(enchantingItem, enchantingBookshelves, enchantingSeed)
        for index in 0..<3 {
            let option = index < options.count ? options[index] : nil
            let y = panelY + 48 + Float(index) * 50
            let affordable = option.map { player.xpLevel >= $0.level && (enchantingLapis?.count ?? 0) >= $0.lapis } ?? false
            let hovered = screenMousePosition.x >= panelX + 96 && screenMousePosition.x < panelX + 364 &&
                          screenMousePosition.y >= y && screenMousePosition.y < y + 40
            uiCanvas.fillRect(x: panelX + 96, y: y, width: 268, height: 40,
                              color: affordable ? (hovered ? SIMD4<Float>(0.4, 0.27, 0.58, 1)
                                                           : SIMD4<Float>(0.28, 0.18, 0.42, 1))
                                                : SIMD4<Float>(0.13, 0.12, 0.16, 1))
            if let option {
                let preview = option.preview.map { $0.id.replacingOccurrences(of: "_", with: " ").uppercased() } ?? "UNKNOWN"
                _ = uiCanvas.text(preview, x: panelX + 106, y: y + 8, scale: 1.15,
                                  color: affordable ? SIMD4<Float>(0.85, 0.76, 1, 1) : SIMD4<Float>(0.42, 0.4, 0.45, 1))
                _ = uiCanvas.text("XP \(option.level)  LAPIS \(option.lapis)", x: panelX + 248, y: y + 23,
                                  scale: 0.9, color: affordable ? SIMD4<Float>(0.5, 1, 0.25, 1) : SIMD4<Float>(0.35, 0.4, 0.3, 1))
            }
        }
        _ = uiCanvas.text("BOOKSHELVES \(enchantingBookshelves)", x: panelX + 98, y: panelY + 202,
                          scale: 1.1, color: SIMD4<Float>(0.64, 0.58, 0.75, 1))
        let inventoryY = panelY + 220
        for row in 0..<3 { for column in 0..<9 {
            let index = 9 + row * 9 + column
            inventorySlot(player.inventory[index], x: panelX + 14 + Float(column) * slot,
                          y: inventoryY + Float(row) * slot, selected: false)
        }}
        for column in 0..<9 {
            inventorySlot(player.inventory[column], x: panelX + 14 + Float(column) * slot,
                          y: inventoryY + 3 * slot + 10, selected: column == player.selectedSlot)
        }
        if let carriedStack { inventoryItem(carriedStack, x: screenMousePosition.x + 6, y: screenMousePosition.y + 6) }
    }

    private func appendAnvilScreen(game: GameCore, width: Float, height: Float) {
        guard let player = game.player else { return }
        let slot: Float = 42
        let panelWidth = slot * 9 + 28, panelHeight: Float = 392
        let panelX = (width - panelWidth) / 2, panelY = (height - panelHeight) / 2
        uiCanvas.fillRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight,
                          color: SIMD4<Float>(0.1, 0.105, 0.115, 0.98))
        _ = uiCanvas.text("REPAIR AND NAME", x: panelX + 14, y: panelY + 14, scale: 1.8)
        textField(anvilName + "_", x: panelX + 126, y: panelY + 42, width: 240, focused: true)
        inventorySlot(anvilLeft, x: panelX + 34, y: panelY + 98, selected: false)
        _ = uiCanvas.text("+", x: panelX + 88, y: panelY + 108, scale: 2.4)
        inventorySlot(anvilRight, x: panelX + 124, y: panelY + 98, selected: false)
        _ = uiCanvas.text("->", x: panelX + 184, y: panelY + 108, scale: 2.4)
        let result = anvilCombine(anvilLeft, anvilRight, anvilName.isEmpty ? nil : anvilName)
        inventorySlot(result?.out, x: panelX + 250, y: panelY + 98, selected: true)
        if let result {
            let affordable = player.xpLevel >= result.cost && result.cost < 40
            _ = uiCanvas.text(result.cost >= 40 ? "TOO EXPENSIVE" : "COST \(result.cost) LEVELS",
                              x: panelX + 304, y: panelY + 111, scale: 1.1,
                              color: affordable ? SIMD4<Float>(0.45, 1, 0.25, 1) : SIMD4<Float>(1, 0.3, 0.3, 1))
        }
        let inventoryY = panelY + 220
        for row in 0..<3 { for column in 0..<9 {
            let index = 9 + row * 9 + column
            inventorySlot(player.inventory[index], x: panelX + 14 + Float(column) * slot,
                          y: inventoryY + Float(row) * slot, selected: false)
        }}
        for column in 0..<9 {
            inventorySlot(player.inventory[column], x: panelX + 14 + Float(column) * slot,
                          y: inventoryY + 3 * slot + 10, selected: column == player.selectedSlot)
        }
        if let carriedStack { inventoryItem(carriedStack, x: screenMousePosition.x + 6, y: screenMousePosition.y + 6) }
    }

    private func appendGrindstoneScreen(game: GameCore, width: Float, height: Float) {
        guard let player = game.player else { return }
        let panelWidth: Float = 406, panelHeight: Float = 392
        let panelX = (width - panelWidth) / 2, panelY = (height - panelHeight) / 2
        uiCanvas.fillRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight,
                          color: SIMD4<Float>(0.11, 0.105, 0.1, 0.98))
        _ = uiCanvas.text("REPAIR AND DISENCHANT", x: panelX + 14, y: panelY + 14, scale: 1.7)
        inventorySlot(grindstoneTop, x: panelX + 48, y: panelY + 58, selected: false)
        inventorySlot(grindstoneBottom, x: panelX + 48, y: panelY + 108, selected: false)
        _ = uiCanvas.text("->", x: panelX + 120, y: panelY + 91, scale: 2.5)
        let result = grindstoneResult(grindstoneTop, grindstoneBottom)
        inventorySlot(result?.out, x: panelX + 190, y: panelY + 84, selected: true)
        if let result, result.xp > 0 {
            _ = uiCanvas.text("RETURNS \(result.xp) XP", x: panelX + 246, y: panelY + 98,
                              scale: 1.1, color: SIMD4<Float>(0.5, 1, 0.3, 1))
        }
        appendWorkstationInventory(player: player, panelX: panelX, panelY: panelY)
        if let carriedStack { inventoryItem(carriedStack, x: screenMousePosition.x + 6, y: screenMousePosition.y + 6) }
    }

    private func stonecutterOptions() -> [StonecutRecipe] {
        guard let input = stonecutterInput else { return [] }
        return stonecuttingRecipes.filter { $0.input == itemName(input.id) }
    }

    private func appendStonecutterScreen(game: GameCore, width: Float, height: Float) {
        guard let player = game.player else { return }
        let panelWidth: Float = 406, panelHeight: Float = 392
        let panelX = (width - panelWidth) / 2, panelY = (height - panelHeight) / 2
        uiCanvas.fillRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight,
                          color: SIMD4<Float>(0.105, 0.11, 0.115, 0.98))
        _ = uiCanvas.text("STONECUTTER", x: panelX + 14, y: panelY + 14, scale: 1.8)
        inventorySlot(stonecutterInput, x: panelX + 26, y: panelY + 74, selected: false)
        let options = stonecutterOptions()
        for index in 0..<min(12, options.count) {
            let x = panelX + 92 + Float(index % 4) * 44, y = panelY + 46 + Float(index / 4) * 44
            uiCanvas.fillRect(x: x, y: y, width: 40, height: 40,
                              color: index == stonecutterSelection ? SIMD4<Float>(0.45, 0.45, 0.75, 1)
                                                                   : SIMD4<Float>(0.16, 0.17, 0.19, 1))
            inventoryItem(ItemStack(iid(options[index].output), options[index].count), x: x + 6, y: y + 8)
        }
        _ = uiCanvas.text("->", x: panelX + 282, y: panelY + 92, scale: 2.3)
        let output = stonecutterSelection >= 0 && stonecutterSelection < options.count
            ? ItemStack(iid(options[stonecutterSelection].output), options[stonecutterSelection].count) : nil
        inventorySlot(output, x: panelX + 334, y: panelY + 82, selected: true)
        appendWorkstationInventory(player: player, panelX: panelX, panelY: panelY)
        if let carriedStack { inventoryItem(carriedStack, x: screenMousePosition.x + 6, y: screenMousePosition.y + 6) }
    }

    private func appendSmithingScreen(game: GameCore, width: Float, height: Float) {
        guard let player = game.player else { return }
        let panelWidth: Float = 406, panelHeight: Float = 392
        let panelX = (width - panelWidth) / 2, panelY = (height - panelHeight) / 2
        uiCanvas.fillRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight,
                          color: SIMD4<Float>(0.08, 0.11, 0.12, 0.98))
        _ = uiCanvas.text("UPGRADE GEAR", x: panelX + 14, y: panelY + 14, scale: 1.8)
        inventorySlot(smithingTemplate, x: panelX + 24, y: panelY + 88, selected: false)
        _ = uiCanvas.text("+", x: panelX + 70, y: panelY + 99, scale: 2)
        inventorySlot(smithingBase, x: panelX + 96, y: panelY + 88, selected: false)
        _ = uiCanvas.text("+", x: panelX + 142, y: panelY + 99, scale: 2)
        inventorySlot(smithingAddition, x: panelX + 168, y: panelY + 88, selected: false)
        _ = uiCanvas.text("->", x: panelX + 220, y: panelY + 99, scale: 2.2)
        let output = matchSmithing(smithingTemplate, smithingBase, smithingAddition)
        inventorySlot(output, x: panelX + 278, y: panelY + 88, selected: true)
        _ = uiCanvas.text("TEMPLATE", x: panelX + 18, y: panelY + 142, scale: 0.9,
                          color: SIMD4<Float>(0.62, 0.7, 0.72, 1))
        _ = uiCanvas.text("BASE", x: panelX + 100, y: panelY + 142, scale: 0.9,
                          color: SIMD4<Float>(0.62, 0.7, 0.72, 1))
        _ = uiCanvas.text("MATERIAL", x: panelX + 158, y: panelY + 142, scale: 0.9,
                          color: SIMD4<Float>(0.62, 0.7, 0.72, 1))
        appendWorkstationInventory(player: player, panelX: panelX, panelY: panelY)
        if let carriedStack { inventoryItem(carriedStack, x: screenMousePosition.x + 6, y: screenMousePosition.y + 6) }
    }

    private let beaconPowers: [(id: String, title: String, level: Int)] = [
        ("speed", "SPEED", 1), ("haste", "HASTE", 1),
        ("resistance", "RESISTANCE", 2), ("jump_boost", "JUMP BOOST", 2),
        ("strength", "STRENGTH", 3),
    ]

    private func appendBeaconScreen(game: GameCore, width: Float, height: Float) {
        guard let player = game.player, let beacon = screenData?.be else { return }
        let panelWidth: Float = 406, panelHeight: Float = 392
        let panelX = (width - panelWidth) / 2, panelY = (height - panelHeight) / 2
        uiCanvas.fillRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight,
                          color: SIMD4<Float>(0.08, 0.13, 0.15, 0.98))
        _ = uiCanvas.text("BEACON  LEVEL \(beacon.levels ?? 0)", x: panelX + 14, y: panelY + 14, scale: 1.8)
        for (index, power) in beaconPowers.enumerated() {
            let x = panelX + 20 + Float(index % 2) * 150, y = panelY + 48 + Float(index / 2) * 44
            let unlocked = (beacon.levels ?? 0) >= power.level
            actionButton(power.title, x: x, y: y, width: 138)
            if !unlocked { uiCanvas.fillRect(x: x, y: y, width: 138, height: 34, color: SIMD4<Float>(0, 0, 0, 0.55)) }
            if beaconPendingPower == power.id {
                uiCanvas.fillRect(x: x, y: y + 30, width: 138, height: 4, color: SIMD4<Float>(0.35, 0.9, 1, 1))
            }
        }
        inventorySlot(beaconPayment, x: panelX + 318, y: panelY + 72, selected: false)
        actionButton("CONFIRM", x: panelX + 268, y: panelY + 132, width: 118)
        appendWorkstationInventory(player: player, panelX: panelX, panelY: panelY)
        if let carriedStack { inventoryItem(carriedStack, x: screenMousePosition.x + 6, y: screenMousePosition.y + 6) }
    }

    private func appendWorkstationInventory(player: Player, panelX: Float, panelY: Float) {
        let slot: Float = 42, inventoryY = panelY + 220
        for row in 0..<3 { for column in 0..<9 {
            let index = 9 + row * 9 + column
            inventorySlot(player.inventory[index], x: panelX + 14 + Float(column) * slot,
                          y: inventoryY + Float(row) * slot, selected: false)
        }}
        for column in 0..<9 {
            inventorySlot(player.inventory[column], x: panelX + 14 + Float(column) * slot,
                          y: inventoryY + 3 * slot + 10, selected: column == player.selectedSlot)
        }
    }

    private func inventorySlot(_ stack: ItemStack?, x: Float, y: Float, selected: Bool) {
        uiCanvas.fillRect(x: x, y: y, width: 38, height: 38,
                          color: selected ? SIMD4<Float>(0.8, 0.82, 0.9, 1)
                                          : SIMD4<Float>(0.025, 0.03, 0.04, 0.95))
        uiCanvas.fillRect(x: x + 2, y: y + 2, width: 34, height: 34,
                          color: SIMD4<Float>(0.16, 0.17, 0.2, 1))
        if let stack {
            inventoryItem(stack, x: x + 4, y: y + 7)
            if screenMousePosition.x >= x, screenMousePosition.x < x + 38,
               screenMousePosition.y >= y, screenMousePosition.y < y + 38 {
                hoveredStack = stack
            }
        }
    }

    private func appendItemTooltip(_ stack: ItemStack, width: Float, height: Float) {
        let definition = itemDef(stack.id)
        var lines = [stack.label?.isEmpty == false ? stack.label! : definition.displayName]
        for enchantment in stack.ench {
            let name = enchDef(enchantment.id).displayName
            lines.append("\(name) \(romanLevel(enchantment.lvl))")
        }
        let durability = definition.tool?.durability ?? definition.armor?.durability ?? 0
        if durability > 0 { lines.append("Durability \(max(0, durability - stack.damage))/\(durability)") }
        if stack.count > 1 { lines.append("Count \(stack.count)") }
        let scale: Float = 1.15
        let tooltipWidth = Float(lines.map(\.count).max() ?? 1) * 6 * scale + 18
        let tooltipHeight = Float(lines.count) * 12 + 14
        let x = min(width - tooltipWidth - 6, screenMousePosition.x + 14)
        let y = min(height - tooltipHeight - 6, screenMousePosition.y + 14)
        uiCanvas.fillRect(x: x, y: y, width: tooltipWidth, height: tooltipHeight,
                          color: SIMD4<Float>(0.025, 0.015, 0.045, 0.97))
        uiCanvas.fillRect(x: x + 2, y: y + 2, width: tooltipWidth - 4, height: tooltipHeight - 4,
                          color: SIMD4<Float>(0.08, 0.045, 0.13, 0.97))
        for (index, line) in lines.enumerated() {
            _ = uiCanvas.text(line, x: x + 9, y: y + 8 + Float(index) * 12, scale: scale,
                              color: index == 0 ? SIMD4<Float>(1, 1, 1, 1) : SIMD4<Float>(0.72, 0.55, 1, 1),
                              shadow: false)
        }
    }

    private func appendSubtitles(width: Float, height: Float) {
        guard activeGame?.settings.subtitles == true else { subtitles.removeAll(); return }
        subtitles = subtitles.compactMap { entry in
            entry.frames > 1 ? (entry.text, entry.frames - 1) : nil
        }
        for (index, entry) in subtitles.suffix(5).reversed().enumerated() {
            let textWidth = Float(entry.text.count * 6) * 1.15 + 16
            let x = width - textWidth - 12, y = height - 92 - Float(index) * 24
            uiCanvas.fillRect(x: x, y: y, width: textWidth, height: 20,
                              color: SIMD4<Float>(0.02, 0.02, 0.025, 0.78))
            _ = uiCanvas.text(entry.text, x: x + 8, y: y + 6, scale: 1.15,
                              color: SIMD4<Float>(1, 1, 1, 1), shadow: false)
        }
    }

    private func addSubtitle(_ sound: String) {
        guard activeGame?.settings.subtitles == true else { return }
        let words = sound.split(separator: ".").dropFirst().map {
            $0.replacingOccurrences(of: "_", with: " ")
        }
        let text = (words.isEmpty ? sound : words.joined(separator: " ")).uppercased()
        if let index = subtitles.firstIndex(where: { $0.text == text }) {
            subtitles[index].frames = 80
        } else {
            subtitles.append((text, 80))
            if subtitles.count > 12 { subtitles.removeFirst(subtitles.count - 12) }
        }
    }

    private func romanLevel(_ level: Int) -> String {
        let values = ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]
        return level >= 0 && level < values.count ? values[level] : "\(level)"
    }

    private func inventoryItem(_ stack: ItemStack, x: Float, y: Float) {
        let cell = stack.id + 1
        let column = cell % 32, row = cell / 32
        let tint = stack.ench.isEmpty ? SIMD4<Float>(1, 1, 1, 1)
                                      : SIMD4<Float>(0.82, 0.68, 1, 1)
        uiCanvas.texturedRect(
            x: x, y: y - 3, width: 28, height: 28,
            u0: Float(column * 16) / Float(uiAtlasWidth) + 0.5 / Float(uiAtlasWidth),
            v0: Float(row * 16) / Float(uiAtlasHeight) + 0.5 / Float(uiAtlasHeight),
            u1: Float(column * 16 + 16) / Float(uiAtlasWidth) - 0.5 / Float(uiAtlasWidth),
            v1: Float(row * 16 + 16) / Float(uiAtlasHeight) - 0.5 / Float(uiAtlasHeight), color: tint)
        if stack.count > 1 {
            _ = uiCanvas.text("\(stack.count)", x: x + 18, y: y + 17, scale: 1,
                              color: SIMD4<Float>(1, 1, 1, 1))
        }
    }

    func screenMouse(x: Float, y: Float) { screenMousePosition = SIMD2<Float>(x, y) }

    func screenMouseButton(_ button: Int, game: GameCore) {
        if button == 0, screenOpen, screenKind == "trading" {
            handleTradeClick(game: game)
            return
        }
        if button == 0, screenOpen, screenKind == "options" {
            handleOptionsClick(game: game)
            return
        }
        if button == 0, screenOpen, screenKind == "title" {
            handleTitleClick(game: game)
            return
        }
        if button == 0, screenOpen, screenKind == "create_world" {
            handleCreateWorldClick(game: game)
            return
        }
        if button == 0, screenOpen, screenKind == "multiplayer" {
            handleMultiplayerClick(game: game)
            return
        }
        if screenOpen, screenKind == "crafting" {
            handleCraftingClick(button: button, game: game)
            return
        }
        if screenOpen, screenKind == "inventory" {
            handlePlayerInventoryClick(button: button, game: game)
            return
        }
        if screenOpen, screenKind == "creative" {
            handleCreativeClick(button: button, game: game)
            return
        }
        if screenOpen, screenKind == "enchanting" {
            handleEnchantingClick(button: button, game: game)
            return
        }
        if screenOpen, screenKind == "anvil" {
            handleAnvilClick(button: button, game: game)
            return
        }
        if screenOpen, screenKind == "grindstone" {
            handleGrindstoneClick(button: button, game: game)
            return
        }
        if screenOpen, screenKind == "stonecutter" {
            handleStonecutterClick(button: button, game: game)
            return
        }
        if screenOpen, screenKind == "smithing" {
            handleSmithingClick(button: button, game: game)
            return
        }
        if screenOpen, screenKind == "beacon" {
            handleBeaconClick(button: button, game: game)
            return
        }
        if button == 0, screenOpen, screenKind == "pause" || screenKind == "death" {
            handleActionScreenClick(game: game)
            return
        }
        if screenOpen, let slot = containerSlotAtMouse(), let player = game.player {
            switch slot {
            case .container(let index, let second):
                let owner = second ? screenData?.other : screenData?.be
                transferSlot(button: button, get: { owner?.items?[index] },
                             set: { owner?.items?[index] = $0 })
            case .player(let index):
                transferSlot(button: button, get: { player.inventory[index] },
                             set: { player.inventory[index] = $0 })
            }
            playUI("ui.button.click")
            return
        }
        guard screenOpen, (screenKind == "inventory" || screenKind == "creative"),
              let player = game.player, let slotIndex = inventorySlotAtMouse() else { return }
        if button == 0 {
            let old = player.inventory[slotIndex]
            player.inventory[slotIndex] = carriedStack
            carriedStack = old
        } else if button == 2 {
            if carriedStack == nil, let stack = player.inventory[slotIndex] {
                let take = (stack.count + 1) / 2
                carriedStack = stack.copy()
                carriedStack?.count = take
                stack.count -= take
                if stack.count <= 0 { player.inventory[slotIndex] = nil }
            } else if let carried = carriedStack {
                if let destination = player.inventory[slotIndex], destination.id == carried.id,
                   destination.count < itemDef(destination.id).maxStack {
                    destination.count += 1
                    carried.count -= 1
                } else if player.inventory[slotIndex] == nil {
                    let one = carried.copy(); one.count = 1
                    player.inventory[slotIndex] = one
                    carried.count -= 1
                }
                if carried.count <= 0 { carriedStack = nil }
            }
        }
        playUI("ui.button.click")
    }

    private func currentTradeOffers() -> [TradeOffer] {
        (tradingMob as? Villager)?.offers ?? (tradingMob as? WanderingTrader)?.offers ?? []
    }

    private func handleTradeClick(game: GameCore) {
        guard let player = game.player else { return }
        let offers = currentTradeOffers()
        let panelWidth: Float = 470
        let panelHeight = min(lastScreenSize.y - 40, Float(max(1, offers.count)) * 46 + 82)
        let x = (lastScreenSize.x - panelWidth) / 2
        let y = (lastScreenSize.y - panelHeight) / 2
        guard screenMousePosition.x >= x + 14 && screenMousePosition.x < x + panelWidth - 14 else { return }
        let index = Int((screenMousePosition.y - (y + 48)) / 46)
        guard index >= 0 && index < min(8, offers.count) else { return }
        let offer = offers[index]
        guard offer.uses < offer.maxUses,
              inventoryCount(player, id: offer.buyA.id) >= offer.buyA.count,
              offer.buyB.map({ inventoryCount(player, id: $0.id) >= $0.count }) ?? true else {
            playUI("entity.villager.no"); return
        }
        consumeInventory(player, id: offer.buyA.id, count: offer.buyA.count)
        if let second = offer.buyB { consumeInventory(player, id: second.id, count: second.count) }
        if !player.give(offer.sell.copy()) {
            _ = spawnItem(game.world, player.x, player.y, player.z, offer.sell.copy())
        }
        if let villager = tradingMob as? Villager {
            villager.offers[index].uses += 1
            villager.addTradeXP(offer.xp)
        } else if let trader = tradingMob as? WanderingTrader {
            trader.offers[index].uses += 1
        }
        game.advance("trade_villager")
        playUI("entity.villager.yes")
    }

    private func inventoryCount(_ player: Player, id: Int) -> Int {
        player.inventory.compactMap { $0 }.filter { $0.id == id }.reduce(0) { $0 + $1.count }
    }

    private func consumeInventory(_ player: Player, id: Int, count: Int) {
        var remaining = count
        for index in player.inventory.indices where remaining > 0 {
            guard let stack = player.inventory[index], stack.id == id else { continue }
            let take = min(remaining, stack.count)
            stack.count -= take; remaining -= take
            if stack.count <= 0 { player.inventory[index] = nil }
        }
    }

    private func handleTitleClick(game: GameCore) {
        let x = screenMousePosition.x
        let y = screenMousePosition.y
        let listX = lastScreenSize.x / 2 - 280, listY = lastScreenSize.y * 0.39
        let rowHeight: Float = 42
        let worlds = game.listWorlds()
        if x >= listX && x < listX + 560 && y >= listY && y < listY + rowHeight * 5 {
            let index = titleWorldOffset + Int((y - listY) / rowHeight)
            if index < worlds.count { titleWorldSelection = index; pendingWorldDeleteID = nil }
            playUI("ui.button.click")
            return
        }
        let buttonY = listY + rowHeight * 5 + 12
        if x >= listX && x < listX + 274 && y >= buttonY && y < buttonY + 34 {
            if !worlds.isEmpty {
                game.loadWorld(worlds[titleWorldSelection].id)
                closeAllScreens()
            } else {
                beginCreateWorld(game: game)
            }
        } else if x >= listX + 286 && x < listX + 560 && y >= buttonY && y < buttonY + 34,
                  !worlds.isEmpty {
            let selected = worlds[titleWorldSelection]
            if pendingWorldDeleteID == selected.id {
                game.deleteWorld(selected.id)
                titleWorldSelection = min(titleWorldSelection, max(0, worlds.count - 2))
                pendingWorldDeleteID = nil
            } else {
                pendingWorldDeleteID = selected.id
            }
        } else if x >= listX && x < listX + 274 && y >= buttonY + 46 && y < buttonY + 80 {
            beginCreateWorld(game: game)
        } else if x >= listX + 286 && x < listX + 560 && y >= buttonY + 46 && y < buttonY + 80 {
            beginMultiplayer(game: game)
        } else if x >= listX && x < listX + 274 && y >= buttonY + 92 && y < buttonY + 126 {
            screenReturnKind = "title"; screenKind = "options"
        } else if x >= listX + 286 && x < listX + 560 &&
                  y >= buttonY + 92 && y < buttonY + 126 {
            exitRequested = true
        } else {
            return
        }
        playUI("ui.button.click")
    }

    private func beginCreateWorld(game: GameCore) {
        createWorldName = "World \(game.listWorlds().count + 1)"
        createWorldSeed = ""
        createWorldField = 0
        createWorldMode = 0
        screenKind = "create_world"
    }

    private func createWorldFromForm(game: GameCore) {
        let name = createWorldName.trimmingCharacters(in: .whitespacesAndNewlines)
        game.createWorld(name: name.isEmpty ? "World \(game.listWorlds().count + 1)" : name,
                         seedText: createWorldSeed, mode: createWorldMode, difficulty: 2)
        closeAllScreens()
    }

    private func handleCreateWorldClick(game: GameCore) {
        let panelWidth: Float = 520, panelHeight: Float = 350
        let x = (lastScreenSize.x - panelWidth) / 2, y = (lastScreenSize.y - panelHeight) / 2
        let mx = screenMousePosition.x, my = screenMousePosition.y
        guard mx >= x + 48 && mx < x + panelWidth - 48 else { return }
        if my >= y + 112 && my < y + 148 { createWorldField = 0 }
        else if my >= y + 188 && my < y + 224 { createWorldField = 1 }
        else if my >= y + 240 && my < y + 274 { createWorldMode = createWorldMode == 0 ? 1 : 0 }
        else if mx < x + 250 && my >= y + 292 && my < y + 326 { createWorldFromForm(game: game) }
        else if mx >= x + 270 && my >= y + 292 && my < y + 326 { screenKind = "title" }
        else { return }
        playUI("ui.button.click")
    }

    private func beginMultiplayer(game: GameCore) {
        multiplayerName = game.settings.playerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if multiplayerName.isEmpty { multiplayerName = "Player" }
        multiplayerField = 0
        multiplayerMessage = ""
        screenKind = "multiplayer"
    }

    private func connectFromForm(game: GameCore) {
        let address = multiplayerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint: NetEndpoint
        switch NetEndpoint.parse(address) {
        case .success(let parsed): endpoint = parsed
        case .failure(let error):
            multiplayerMessage = "INVALID ADDRESS: \(error)"
            return
        }
        let name = multiplayerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { multiplayerMessage = "PLAYER NAME IS REQUIRED"; return }
        game.settings.playerName = name
        game.applySettings()
        let skin = (try? Data(contentsOf: customSkinURL)) ?? Data()
        _ = game.joinLan(netDial(endpoint), name: name, skin: skin)
        closeAllScreens()
    }

    private func handleMultiplayerClick(game: GameCore) {
        let panelWidth: Float = 520, panelHeight: Float = 350
        let x = (lastScreenSize.x - panelWidth) / 2, y = (lastScreenSize.y - panelHeight) / 2
        let mx = screenMousePosition.x, my = screenMousePosition.y
        guard mx >= x + 48 && mx < x + panelWidth - 48 else { return }
        if my >= y + 112 && my < y + 148 { multiplayerField = 0 }
        else if my >= y + 188 && my < y + 224 { multiplayerField = 1 }
        else if mx < x + 250 && my >= y + 292 && my < y + 326 { connectFromForm(game: game) }
        else if mx >= x + 270 && my >= y + 292 && my < y + 326 { screenKind = "title" }
        else { return }
        playUI("ui.button.click")
    }

    private func handleOptionsClick(game: GameCore) {
        let x = lastScreenSize.x / 2 - 190
        let y = lastScreenSize.y * 0.27
        guard screenMousePosition.x >= x && screenMousePosition.x < x + 380 else { return }
        let localY = screenMousePosition.y - y
        let row = Int(localY / 36)
        guard localY >= 0 else { return }
        switch row {
        case 0: game.settings.renderDistance = game.settings.renderDistance >= 16 ? 4 : game.settings.renderDistance + 2
        case 1: game.settings.fov = game.settings.fov >= 110 ? 50 : game.settings.fov + 5
        case 2: game.settings.entityDistance = game.settings.entityDistance >= 128 ? 32 : game.settings.entityDistance + 16
        case 3: game.settings.shadows.toggle()
        case 4: game.settings.clouds.toggle()
        case 5: game.settings.particles = (game.settings.particles + 1) % 3
        case 6: game.settings.shader = game.settings.shader == "ultra" ? nil : "ultra"
        case 7: game.settings.gamma = game.settings.gamma >= 1 ? 0 : min(1, game.settings.gamma + 0.2)
        case 8: game.settings.viewBobbing.toggle()
        case 9: game.settings.sensitivity = game.settings.sensitivity >= 1 ? 0.1 : min(1, game.settings.sensitivity + 0.1)
        case 10: game.settings.invertY.toggle()
        case 11: game.settings.autoJump.toggle()
        case 12: game.settings.subtitles.toggle()
        case 13:
            let value = game.settings.volumes["master"] ?? 0.8
            game.settings.volumes["master"] = value >= 1 ? 0 : min(1, value + 0.1)
        case 14:
            let value = game.settings.volumes["music"] ?? 0.5
            game.settings.volumes["music"] = value >= 1 ? 0 : min(1, value + 0.1)
        case 15:
            game.applySettings(); screenKind = screenReturnKind
        default: return
        }
        game.applySettings()
        playUI("ui.button.click")
    }

    private func handleActionScreenClick(game: GameCore) {
        let centerX = lastScreenSize.x / 2
        let x = screenMousePosition.x
        let y = screenMousePosition.y
        guard x >= centerX - 130 && x < centerX + 130 else { return }
        if screenKind == "death" {
            if y >= lastScreenSize.y / 2 && y < lastScreenSize.y / 2 + 34 {
                game.respawnPlayer(); closeAllScreens()
            } else if y >= lastScreenSize.y / 2 + 48 && y < lastScreenSize.y / 2 + 82 {
                game.saveAndFlush(synchronous: true); exitRequested = true
            }
        } else if y >= lastScreenSize.y / 2 - 54 && y < lastScreenSize.y / 2 - 20 {
            closeAllScreens()
        } else if y >= lastScreenSize.y / 2 - 6 && y < lastScreenSize.y / 2 + 28 {
            if game.netHost == nil && game.netGuest == nil, game.startLanHost() { closeAllScreens() }
        } else if y >= lastScreenSize.y / 2 + 42 && y < lastScreenSize.y / 2 + 76 {
            screenReturnKind = "pause"; screenKind = "options"
        } else if y >= lastScreenSize.y / 2 + 90 && y < lastScreenSize.y / 2 + 124 {
            game.saveAndFlush(synchronous: true); exitRequested = true
        }
        playUI("ui.button.click")
    }

    private enum ContainerSlotHit { case container(Int, Bool), player(Int) }

    private func containerSlotAtMouse() -> ContainerSlotHit? {
        guard let first = screenData?.be?.items else { return nil }
        let secondCount = screenData?.other?.items?.count ?? 0
        let total = first.count + secondCount
        let rows = max(1, (total + 8) / 9)
        let slot: Float = 42
        let panelWidth = slot * 9 + 28
        let panelHeight = Float(rows + 4) * slot + 74
        let panelX = (lastScreenSize.x - panelWidth) / 2
        let panelY = max(12, (lastScreenSize.y - panelHeight) / 2)
        let gridX = panelX + 14
        let localX = screenMousePosition.x - gridX
        guard localX >= 0 else { return nil }
        let column = Int(localX / slot)
        guard column >= 0 && column < 9,
              localX.truncatingRemainder(dividingBy: slot) < 38 else { return nil }
        let containerY = panelY + 42
        let localContainerY = screenMousePosition.y - containerY
        if localContainerY >= 0 {
            let row = Int(localContainerY / slot)
            if row >= 0 && row < rows && localContainerY.truncatingRemainder(dividingBy: slot) < 38 {
                let index = row * 9 + column
                if index < total {
                    return index < first.count ? .container(index, false)
                        : .container(index - first.count, true)
                }
            }
        }
        let playerY = containerY + Float(rows) * slot + 18
        let localPlayerY = screenMousePosition.y - playerY
        if localPlayerY >= 0 {
            let row = Int(localPlayerY / slot)
            if row >= 0 && row < 3 && localPlayerY.truncatingRemainder(dividingBy: slot) < 38 {
                return .player(9 + row * 9 + column)
            }
        }
        let hotbarY = playerY + 3 * slot + 10
        if screenMousePosition.y >= hotbarY && screenMousePosition.y < hotbarY + 38 { return .player(column) }
        return nil
    }

    private func transferSlot(button: Int, get: () -> ItemStack?, set: (ItemStack?) -> Void) {
        if button == 0 {
            let old = get()
            set(carriedStack)
            carriedStack = old
        } else if button == 2 {
            if carriedStack == nil, let stack = get() {
                let take = (stack.count + 1) / 2
                carriedStack = stack.copy(); carriedStack?.count = take
                stack.count -= take
                if stack.count <= 0 { set(nil) }
            } else if let carried = carriedStack {
                if let destination = get(), destination.id == carried.id,
                   destination.count < itemDef(destination.id).maxStack {
                    destination.count += 1; carried.count -= 1
                } else if get() == nil {
                    let one = carried.copy(); one.count = 1; set(one); carried.count -= 1
                }
                if carried.count <= 0 { carriedStack = nil }
            }
        }
    }

    private enum CraftingHit { case grid(Int), output, player(Int) }

    private func craftingHitAtMouse() -> CraftingHit? {
        let slot: Float = 42
        let panelWidth = slot * 9 + 28, panelHeight: Float = 392
        let panelX = (lastScreenSize.x - panelWidth) / 2
        let panelY = (lastScreenSize.y - panelHeight) / 2
        let x = screenMousePosition.x, y = screenMousePosition.y
        let craftX = panelX + 42, craftY = panelY + 48
        let craftColumn = Int((x - craftX) / slot), craftRow = Int((y - craftY) / slot)
        if x >= craftX, y >= craftY, craftColumn >= 0, craftColumn < 3,
           craftRow >= 0, craftRow < 3,
           (x - craftX).truncatingRemainder(dividingBy: slot) < 38,
           (y - craftY).truncatingRemainder(dividingBy: slot) < 38 {
            return .grid(craftRow * 3 + craftColumn)
        }
        if x >= panelX + 262, x < panelX + 300, y >= panelY + 90, y < panelY + 128 {
            return .output
        }
        let inventoryY = panelY + 220, inventoryX = panelX + 14
        let column = Int((x - inventoryX) / slot)
        guard x >= inventoryX, column >= 0, column < 9,
              (x - inventoryX).truncatingRemainder(dividingBy: slot) < 38 else { return nil }
        let mainRow = Int((y - inventoryY) / slot)
        if y >= inventoryY, mainRow >= 0, mainRow < 3,
           (y - inventoryY).truncatingRemainder(dividingBy: slot) < 38 {
            return .player(9 + mainRow * 9 + column)
        }
        let hotbarY = inventoryY + 3 * slot + 10
        if y >= hotbarY, y < hotbarY + 38 { return .player(column) }
        return nil
    }

    private func handleCraftingClick(button: Int, game: GameCore) {
        guard let player = game.player, let hit = craftingHitAtMouse() else { return }
        switch hit {
        case .grid(let index):
            transferSlot(button: button, get: { self.craftingGrid[index] },
                         set: { self.craftingGrid[index] = $0 })
        case .player(let index):
            transferSlot(button: button, get: { player.inventory[index] },
                         set: { player.inventory[index] = $0 })
        case .output:
            guard let result = matchCrafting(craftingGrid, 3, 3)?.out else { return }
            if let carried = carriedStack {
                guard carried.id == result.id,
                      carried.count + result.count <= itemDef(result.id).maxStack else { return }
                carried.count += result.count
            } else {
                carriedStack = result.copy()
            }
            let returns = consumeCraftingGrid(&craftingGrid)
            for item in returns where !player.give(item) {
                _ = spawnItem(game.world, player.x, player.y, player.z, item)
            }
            game.advance("craft_any")
        }
        playUI("ui.button.click")
    }

    private func returnCraftingGrid() {
        guard let game = activeGame, let player = game.player else { return }
        for index in craftingGrid.indices {
            guard let stack = craftingGrid[index] else { continue }
            if !player.give(stack) { _ = spawnItem(game.world, player.x, player.y, player.z, stack) }
            craftingGrid[index] = nil
        }
    }

    private enum PlayerInventoryHit {
        case craft(Int), output, armor(Int), offhand, player(Int)
    }

    private func playerInventoryHitAtMouse() -> PlayerInventoryHit? {
        let slot: Float = 42
        let panelWidth = slot * 9 + 28, panelHeight: Float = 392
        let panelX = (lastScreenSize.x - panelWidth) / 2
        let panelY = (lastScreenSize.y - panelHeight) / 2
        let x = screenMousePosition.x, y = screenMousePosition.y
        for armorSlot in 0..<4 {
            let sy = panelY + 46 + Float(armorSlot) * slot
            if x >= panelX + 14, x < panelX + 52, y >= sy, y < sy + 38 { return .armor(armorSlot) }
        }
        if x >= panelX + 70, x < panelX + 108, y >= panelY + 88, y < panelY + 126 { return .offhand }
        let craftX = panelX + 158, craftY = panelY + 58
        if x >= craftX, y >= craftY {
            let column = Int((x - craftX) / slot), row = Int((y - craftY) / slot)
            if column >= 0, column < 2, row >= 0, row < 2,
               (x - craftX).truncatingRemainder(dividingBy: slot) < 38,
               (y - craftY).truncatingRemainder(dividingBy: slot) < 38 {
                return .craft(row * 2 + column)
            }
        }
        if x >= panelX + 308, x < panelX + 346, y >= panelY + 80, y < panelY + 118 { return .output }
        let inventoryX = panelX + 14, inventoryY = panelY + 220
        let column = Int((x - inventoryX) / slot)
        guard x >= inventoryX, column >= 0, column < 9,
              (x - inventoryX).truncatingRemainder(dividingBy: slot) < 38 else { return nil }
        let row = Int((y - inventoryY) / slot)
        if y >= inventoryY, row >= 0, row < 3,
           (y - inventoryY).truncatingRemainder(dividingBy: slot) < 38 {
            return .player(9 + row * 9 + column)
        }
        let hotbarY = inventoryY + 3 * slot + 10
        if y >= hotbarY, y < hotbarY + 38 { return .player(column) }
        return nil
    }

    private func handlePlayerInventoryClick(button: Int, game: GameCore) {
        guard let player = game.player, let hit = playerInventoryHitAtMouse() else { return }
        switch hit {
        case .craft(let index):
            transferSlot(button: button, get: { self.inventoryCraftingGrid[index] },
                         set: { self.inventoryCraftingGrid[index] = $0 })
        case .player(let index):
            transferSlot(button: button, get: { player.inventory[index] },
                         set: { player.inventory[index] = $0 })
        case .offhand:
            transferSlot(button: button, get: { player.offHand }, set: { player.offHand = $0 })
        case .armor(let index):
            if let carried = carriedStack,
               itemDef(carried.id).armor?.slot != index { return }
            transferSlot(button: button, get: { player.armor[index] }, set: { player.armor[index] = $0 })
        case .output:
            guard let result = matchCrafting(inventoryCraftingGrid, 2, 2)?.out else { return }
            if let carried = carriedStack {
                guard carried.id == result.id,
                      carried.count + result.count <= itemDef(result.id).maxStack else { return }
                carried.count += result.count
            } else {
                carriedStack = result.copy()
            }
            let returns = consumeCraftingGrid(&inventoryCraftingGrid)
            for item in returns where !player.give(item) {
                _ = spawnItem(game.world, player.x, player.y, player.z, item)
            }
            game.advance("craft_any")
        }
        playUI("ui.button.click")
    }

    private func handleCreativeClick(button: Int, game: GameCore) {
        guard let player = game.player else { return }
        let slot: Float = 42, panelWidth = slot * 9 + 28, panelHeight: Float = 310
        let panelX = (lastScreenSize.x - panelWidth) / 2, panelY = (lastScreenSize.y - panelHeight) / 2
        let x = screenMousePosition.x, y = screenMousePosition.y
        let gridX = panelX + 14, gridY = panelY + 46
        if x >= gridX, y >= gridY {
            let column = Int((x - gridX) / slot), row = Int((y - gridY) / slot)
            if column >= 0, column < 9, row >= 0, row < 4,
               (x - gridX).truncatingRemainder(dividingBy: slot) < 38,
               (y - gridY).truncatingRemainder(dividingBy: slot) < 38 {
                let source = creativeScrollRow * 9 + row * 9 + column
                let ids = creativeItemIDs
                if source < ids.count {
                    let count = button == 2 ? 1 : itemDef(ids[source]).maxStack
                    carriedStack = ItemStack(ids[source], count)
                    playUI("ui.button.click")
                }
                return
            }
        }
        let hotbarY = panelY + 248
        if x >= gridX, x < gridX + slot * 9, y >= hotbarY, y < hotbarY + 38 {
            let column = Int((x - gridX) / slot)
            guard column >= 0, column < 9,
                  (x - gridX).truncatingRemainder(dividingBy: slot) < 38 else { return }
            transferSlot(button: button, get: { player.inventory[column] }, set: { player.inventory[column] = $0 })
            playUI("ui.button.click")
        }
    }

    private func returnInventoryCraftingGrid() {
        guard let game = activeGame, let player = game.player else { return }
        for index in inventoryCraftingGrid.indices {
            guard let stack = inventoryCraftingGrid[index] else { continue }
            if !player.give(stack) { _ = spawnItem(game.world, player.x, player.y, player.z, stack) }
            inventoryCraftingGrid[index] = nil
        }
    }

    private func handleEnchantingClick(button: Int, game: GameCore) {
        guard let player = game.player else { return }
        let slot: Float = 42
        let panelWidth = slot * 9 + 28, panelHeight: Float = 392
        let panelX = (lastScreenSize.x - panelWidth) / 2, panelY = (lastScreenSize.y - panelHeight) / 2
        let x = screenMousePosition.x, y = screenMousePosition.y
        if x >= panelX + 96, x < panelX + 364, y >= panelY + 48, y < panelY + 188 {
            let index = Int((y - panelY - 48) / 50)
            let options = enchantingOptions(enchantingItem, enchantingBookshelves, enchantingSeed)
            if index < options.count, let item = enchantingItem {
                let option = options[index]
                if player.xpLevel >= option.level, (enchantingLapis?.count ?? 0) >= option.lapis {
                    enchantingItem = applyEnchanting(item, option)
                    enchantingLapis?.count -= option.lapis
                    if enchantingLapis?.count ?? 0 <= 0 { enchantingLapis = nil }
                    player.takeLevels(option.lapis)
                    enchantingSeed = enchantingSeed &* 1664525 &+ 1013904223
                    game.advance("enchant_item")
                    playUI("block.enchantment_table.use")
                }
            }
            return
        }
        if x >= panelX + 28, x < panelX + 66, y >= panelY + 66, y < panelY + 104 {
            transferSlot(button: button, get: { self.enchantingItem }, set: { self.enchantingItem = $0 })
        } else if x >= panelX + 28, x < panelX + 66, y >= panelY + 116, y < panelY + 154 {
            if let carried = carriedStack, itemName(carried.id) != "lapis_lazuli" { return }
            transferSlot(button: button, get: { self.enchantingLapis }, set: { self.enchantingLapis = $0 })
        } else {
            let inventoryX = panelX + 14, inventoryY = panelY + 220
            let column = Int((x - inventoryX) / slot)
            guard x >= inventoryX, column >= 0, column < 9,
                  (x - inventoryX).truncatingRemainder(dividingBy: slot) < 38 else { return }
            let row = Int((y - inventoryY) / slot)
            let inventoryIndex: Int
            if y >= inventoryY, row >= 0, row < 3,
               (y - inventoryY).truncatingRemainder(dividingBy: slot) < 38 { inventoryIndex = 9 + row * 9 + column }
            else if y >= inventoryY + 3 * slot + 10, y < inventoryY + 3 * slot + 48 { inventoryIndex = column }
            else { return }
            transferSlot(button: button, get: { player.inventory[inventoryIndex] },
                         set: { player.inventory[inventoryIndex] = $0 })
        }
        playUI("ui.button.click")
    }

    private func returnEnchantingItems() {
        guard let game = activeGame, let player = game.player else { return }
        for stack in [enchantingItem, enchantingLapis].compactMap({ $0 }) {
            if !player.give(stack) { _ = spawnItem(game.world, player.x, player.y, player.z, stack) }
        }
        enchantingItem = nil; enchantingLapis = nil
    }

    private func handleAnvilClick(button: Int, game: GameCore) {
        guard let player = game.player else { return }
        let slot: Float = 42
        let panelWidth = slot * 9 + 28, panelHeight: Float = 392
        let panelX = (lastScreenSize.x - panelWidth) / 2, panelY = (lastScreenSize.y - panelHeight) / 2
        let x = screenMousePosition.x, y = screenMousePosition.y
        if x >= panelX + 34, x < panelX + 72, y >= panelY + 98, y < panelY + 136 {
            transferSlot(button: button, get: { self.anvilLeft },
                         set: { self.anvilLeft = $0; self.anvilName = $0?.label ?? "" })
        } else if x >= panelX + 124, x < panelX + 162, y >= panelY + 98, y < panelY + 136 {
            transferSlot(button: button, get: { self.anvilRight }, set: { self.anvilRight = $0 })
        } else if x >= panelX + 250, x < panelX + 288, y >= panelY + 98, y < panelY + 136 {
            guard let result = anvilCombine(anvilLeft, anvilRight, anvilName.isEmpty ? nil : anvilName),
                  result.cost < 40, player.xpLevel >= result.cost else { return }
            if let carried = carriedStack {
                guard carried.id == result.out.id,
                      carried.count + result.out.count <= itemDef(result.out.id).maxStack else { return }
                carried.count += result.out.count
            } else { carriedStack = result.out.copy() }
            player.takeLevels(result.cost)
            anvilLeft = nil
            if let units = result.out.data.repairUnits, let right = anvilRight, right.count > units {
                right.count -= units
            } else { anvilRight = nil }
            carriedStack?.data.repairUnits = nil
            game.advance("use_anvil")
            playUI("block.anvil.use")
        } else {
            let inventoryX = panelX + 14, inventoryY = panelY + 220
            let column = Int((x - inventoryX) / slot)
            guard x >= inventoryX, column >= 0, column < 9,
                  (x - inventoryX).truncatingRemainder(dividingBy: slot) < 38 else { return }
            let row = Int((y - inventoryY) / slot)
            let index: Int
            if y >= inventoryY, row >= 0, row < 3,
               (y - inventoryY).truncatingRemainder(dividingBy: slot) < 38 { index = 9 + row * 9 + column }
            else if y >= inventoryY + 3 * slot + 10, y < inventoryY + 3 * slot + 48 { index = column }
            else { return }
            transferSlot(button: button, get: { player.inventory[index] }, set: { player.inventory[index] = $0 })
        }
        playUI("ui.button.click")
    }

    private func returnAnvilItems() {
        guard let game = activeGame, let player = game.player else { return }
        for stack in [anvilLeft, anvilRight].compactMap({ $0 }) {
            if !player.give(stack) { _ = spawnItem(game.world, player.x, player.y, player.z, stack) }
        }
        anvilLeft = nil; anvilRight = nil; anvilName = ""
    }

    private func workstationInventoryIndex(panelX: Float, panelY: Float) -> Int? {
        let slot: Float = 42, inventoryY = panelY + 220
        let x = screenMousePosition.x, y = screenMousePosition.y
        let column = Int((x - panelX - 14) / slot)
        guard x >= panelX + 14, column >= 0, column < 9,
              (x - panelX - 14).truncatingRemainder(dividingBy: slot) < 38 else { return nil }
        let row = Int((y - inventoryY) / slot)
        if y >= inventoryY, row >= 0, row < 3,
           (y - inventoryY).truncatingRemainder(dividingBy: slot) < 38 { return 9 + row * 9 + column }
        let hotbarY = inventoryY + 3 * slot + 10
        return y >= hotbarY && y < hotbarY + 38 ? column : nil
    }

    private func handleGrindstoneClick(button: Int, game: GameCore) {
        guard let player = game.player else { return }
        let panelX = (lastScreenSize.x - 406) / 2, panelY = (lastScreenSize.y - 392) / 2
        let x = screenMousePosition.x, y = screenMousePosition.y
        if x >= panelX + 48, x < panelX + 86, y >= panelY + 58, y < panelY + 96 {
            transferSlot(button: button, get: { self.grindstoneTop }, set: { self.grindstoneTop = $0 })
        } else if x >= panelX + 48, x < panelX + 86, y >= panelY + 108, y < panelY + 146 {
            transferSlot(button: button, get: { self.grindstoneBottom }, set: { self.grindstoneBottom = $0 })
        } else if x >= panelX + 190, x < panelX + 228, y >= panelY + 84, y < panelY + 122 {
            guard let result = grindstoneResult(grindstoneTop, grindstoneBottom) else { return }
            if let carried = carriedStack {
                guard carried.id == result.out.id,
                      carried.count + result.out.count <= itemDef(result.out.id).maxStack else { return }
                carried.count += result.out.count
            } else { carriedStack = result.out.copy() }
            grindstoneTop = nil; grindstoneBottom = nil
            if result.xp > 0 { spawnXP(game.world, player.x, player.y, player.z, result.xp) }
            playUI("block.grindstone.use")
        } else if let index = workstationInventoryIndex(panelX: panelX, panelY: panelY) {
            transferSlot(button: button, get: { player.inventory[index] }, set: { player.inventory[index] = $0 })
        } else { return }
        playUI("ui.button.click")
    }

    private func returnGrindstoneItems() {
        guard let game = activeGame, let player = game.player else { return }
        for stack in [grindstoneTop, grindstoneBottom].compactMap({ $0 }) {
            if !player.give(stack) { _ = spawnItem(game.world, player.x, player.y, player.z, stack) }
        }
        grindstoneTop = nil; grindstoneBottom = nil
    }

    private func handleStonecutterClick(button: Int, game: GameCore) {
        guard let player = game.player else { return }
        let panelX = (lastScreenSize.x - 406) / 2, panelY = (lastScreenSize.y - 392) / 2
        let x = screenMousePosition.x, y = screenMousePosition.y
        if x >= panelX + 26, x < panelX + 64, y >= panelY + 74, y < panelY + 112 {
            transferSlot(button: button, get: { self.stonecutterInput }, set: {
                self.stonecutterInput = $0; self.stonecutterSelection = -1
            })
        } else if x >= panelX + 92, x < panelX + 268, y >= panelY + 46, y < panelY + 178 {
            let index = Int((x - panelX - 92) / 44) + Int((y - panelY - 46) / 44) * 4
            if index < stonecutterOptions().count { stonecutterSelection = index; playUI("ui.stonecutter.select_recipe") }
            return
        } else if x >= panelX + 334, x < panelX + 372, y >= panelY + 82, y < panelY + 120 {
            let options = stonecutterOptions()
            guard stonecutterSelection >= 0, stonecutterSelection < options.count,
                  let input = stonecutterInput else { return }
            let recipe = options[stonecutterSelection]
            let output = ItemStack(iid(recipe.output), recipe.count)
            if let carried = carriedStack {
                guard carried.id == output.id,
                      carried.count + output.count <= itemDef(output.id).maxStack else { return }
                carried.count += output.count
            } else { carriedStack = output }
            input.count -= 1
            if input.count <= 0 { stonecutterInput = nil; stonecutterSelection = -1 }
            playUI("ui.stonecutter.take_result")
        } else if let index = workstationInventoryIndex(panelX: panelX, panelY: panelY) {
            transferSlot(button: button, get: { player.inventory[index] }, set: { player.inventory[index] = $0 })
        } else { return }
        playUI("ui.button.click")
    }

    private func returnStonecutterInput() {
        guard let game = activeGame, let player = game.player, let input = stonecutterInput else { return }
        if !player.give(input) { _ = spawnItem(game.world, player.x, player.y, player.z, input) }
        stonecutterInput = nil; stonecutterSelection = -1
    }

    private func handleSmithingClick(button: Int, game: GameCore) {
        guard let player = game.player else { return }
        let panelX = (lastScreenSize.x - 406) / 2, panelY = (lastScreenSize.y - 392) / 2
        let x = screenMousePosition.x, y = screenMousePosition.y
        if x >= panelX + 24, x < panelX + 62, y >= panelY + 88, y < panelY + 126 {
            transferSlot(button: button, get: { self.smithingTemplate }, set: { self.smithingTemplate = $0 })
        } else if x >= panelX + 96, x < panelX + 134, y >= panelY + 88, y < panelY + 126 {
            transferSlot(button: button, get: { self.smithingBase }, set: { self.smithingBase = $0 })
        } else if x >= panelX + 168, x < panelX + 206, y >= panelY + 88, y < panelY + 126 {
            transferSlot(button: button, get: { self.smithingAddition }, set: { self.smithingAddition = $0 })
        } else if x >= panelX + 278, x < panelX + 316, y >= panelY + 88, y < panelY + 126 {
            guard let output = matchSmithing(smithingTemplate, smithingBase, smithingAddition) else { return }
            if let carried = carriedStack {
                guard carried.id == output.id,
                      carried.count + output.count <= itemDef(output.id).maxStack else { return }
                carried.count += output.count
            } else { carriedStack = output.copy() }
            consumeSmithingInput(&smithingTemplate)
            consumeSmithingInput(&smithingBase)
            consumeSmithingInput(&smithingAddition)
            game.advance("use_smithing_table")
            playUI("block.smithing_table.use")
        } else if let index = workstationInventoryIndex(panelX: panelX, panelY: panelY) {
            transferSlot(button: button, get: { player.inventory[index] }, set: { player.inventory[index] = $0 })
        } else { return }
        playUI("ui.button.click")
    }

    private func consumeSmithingInput(_ stack: inout ItemStack?) {
        stack?.count -= 1
        if stack?.count ?? 0 <= 0 { stack = nil }
    }

    private func returnSmithingItems() {
        guard let game = activeGame, let player = game.player else { return }
        for stack in [smithingTemplate, smithingBase, smithingAddition].compactMap({ $0 }) {
            if !player.give(stack) { _ = spawnItem(game.world, player.x, player.y, player.z, stack) }
        }
        smithingTemplate = nil; smithingBase = nil; smithingAddition = nil
    }

    private func handleBeaconClick(button: Int, game: GameCore) {
        guard let player = game.player, let beacon = screenData?.be else { return }
        let panelX = (lastScreenSize.x - 406) / 2, panelY = (lastScreenSize.y - 392) / 2
        let x = screenMousePosition.x, y = screenMousePosition.y
        for (index, power) in beaconPowers.enumerated() {
            let bx = panelX + 20 + Float(index % 2) * 150, by = panelY + 48 + Float(index / 2) * 44
            if x >= bx, x < bx + 138, y >= by, y < by + 34, (beacon.levels ?? 0) >= power.level {
                beaconPendingPower = power.id; playUI("ui.button.click"); return
            }
        }
        if x >= panelX + 318, x < panelX + 356, y >= panelY + 72, y < panelY + 110 {
            if let carried = carriedStack,
               !["iron_ingot", "gold_ingot", "diamond", "emerald", "netherite_ingot"].contains(itemName(carried.id)) { return }
            transferSlot(button: button, get: { self.beaconPayment }, set: { self.beaconPayment = $0 })
        } else if x >= panelX + 268, x < panelX + 386, y >= panelY + 132, y < panelY + 166 {
            guard let power = beaconPendingPower, let payment = beaconPayment, (beacon.levels ?? 0) > 0 else { return }
            beacon.primary = power
            beacon.secondary = (beacon.levels ?? 0) >= 4 ? power : nil
            payment.count -= 1
            if payment.count <= 0 { beaconPayment = nil }
            playUI("block.beacon.power_select")
            closeAllScreens()
            return
        } else if let index = workstationInventoryIndex(panelX: panelX, panelY: panelY) {
            transferSlot(button: button, get: { player.inventory[index] }, set: { player.inventory[index] = $0 })
        } else { return }
        playUI("ui.button.click")
    }

    private func returnBeaconPayment() {
        guard let game = activeGame, let player = game.player, let payment = beaconPayment else { return }
        if !player.give(payment) { _ = spawnItem(game.world, player.x, player.y, player.z, payment) }
        beaconPayment = nil
    }

    private func inventorySlotAtMouse() -> Int? {
        let slot: Float = 42
        let panelWidth = slot * 9 + 28
        let panelHeight: Float = 236
        let panelX = (lastScreenSize.x - panelWidth) / 2
        let panelY = (lastScreenSize.y - panelHeight) / 2
        let gridX = panelX + 14
        let x = screenMousePosition.x - gridX
        guard x >= 0 else { return nil }
        let column = Int(x / slot)
        guard column >= 0 && column < 9, x.truncatingRemainder(dividingBy: slot) < 38 else { return nil }
        let mainY = panelY + 48
        let mainRelativeY = screenMousePosition.y - mainY
        if mainRelativeY >= 0 {
            let row = Int(mainRelativeY / slot)
            if row >= 0 && row < 3 && mainRelativeY.truncatingRemainder(dividingBy: slot) < 38 {
                return 9 + row * 9 + column
            }
        }
        let hotbarY = panelY + 182
        if screenMousePosition.y >= hotbarY && screenMousePosition.y < hotbarY + 38 { return column }
        return nil
    }

    private func appendSurvivalHUD(game: GameCore, width: Float, height: Float) {
        guard let player = game.player else { return }
        let slot: Float = 40
        let barWidth = slot * 9
        let left = (width - barWidth) / 2
        let top = height - 58
        for index in 0..<9 {
            let x = left + Float(index) * slot
            let selected = index == player.selectedSlot
            uiCanvas.fillRect(x: x, y: top, width: slot - 2, height: 38,
                              color: selected ? SIMD4<Float>(0.9, 0.9, 0.94, 0.9)
                                              : SIMD4<Float>(0.05, 0.05, 0.07, 0.78))
            uiCanvas.fillRect(x: x + 2, y: top + 2, width: slot - 6, height: 34,
                              color: SIMD4<Float>(0.13, 0.14, 0.17, 0.92))
            if let stack = player.inventory[index] {
                inventoryItem(stack, x: x + 5, y: top + 8)
            }
        }
        let healthWidth: Float = 160
        let healthRatio = Float(max(0, min(1, player.health / max(1, player.maxHealth))))
        let hungerRatio = Float(max(0, min(1, Double(player.hunger) / 20)))
        meter(x: left, y: top - 20, width: healthWidth, ratio: healthRatio,
              fill: SIMD4<Float>(0.86, 0.12, 0.16, 1), label: "HP \(Int(player.health.rounded(.up)))")
        meter(x: left + barWidth - healthWidth, y: top - 20, width: healthWidth, ratio: hungerRatio,
              fill: SIMD4<Float>(0.9, 0.55, 0.12, 1), label: "FOOD \(player.hunger)")
        if player.armorValue() > 0 {
            _ = uiCanvas.text("ARMOR \(Int(player.armorValue()))", x: left, y: top - 38, scale: 1.1,
                              color: SIMD4<Float>(0.65, 0.78, 0.92, 1))
        }
        if player.xpLevel > 0 || player.xpProgress > 0 {
            meter(x: left, y: top + 42, width: barWidth - 2, ratio: Float(player.xpProgress),
                  fill: SIMD4<Float>(0.3, 0.9, 0.22, 1), label: "LEVEL \(player.xpLevel)")
        }
        for (index, boss) in bossBars.prefix(3).enumerated() {
            let bossWidth = min(420, width * 0.55)
            let x = (width - bossWidth) / 2
            let y = 18 + Float(index) * 30
            uiCanvas.textCentered(boss.name, centerX: width / 2, y: y, scale: 1.4)
            meter(x: x, y: y + 13, width: bossWidth, ratio: Float(max(0, min(1, boss.progress))),
                  fill: SIMD4<Float>(0.63, 0.2, 0.72, 1), label: "")
        }
        if actionBarFrames > 0 {
            uiCanvas.textCentered(actionBarText, centerX: width / 2, y: top - 54, scale: 1.6,
                                  color: SIMD4<Float>(1, 0.95, 0.65, 1))
            actionBarFrames -= 1
        }
        for (index, line) in chatLines.suffix(6).enumerated() {
            _ = uiCanvas.text(line, x: 12, y: height - 145 - Float(index) * 14, scale: 1.1,
                              color: SIMD4<Float>(0.95, 0.95, 0.98, 0.95))
        }
        if !toasts.isEmpty {
            let toast = toasts[0]
            let toastWidth: Float = 330
            let x = width - toastWidth - 18
            let y: Float = 18
            let accent: SIMD4<Float> = toast.definition.frame == "challenge"
                ? SIMD4<Float>(0.72, 0.28, 0.82, 1) : SIMD4<Float>(0.9, 0.65, 0.18, 1)
            uiCanvas.fillRect(x: x, y: y, width: toastWidth, height: 58,
                              color: SIMD4<Float>(0.045, 0.05, 0.065, 0.96))
            uiCanvas.fillRect(x: x, y: y, width: 5, height: 58, color: accent)
            _ = uiCanvas.text(toast.definition.frame == "challenge" ? "CHALLENGE COMPLETE" : "ADVANCEMENT MADE",
                              x: x + 16, y: y + 9, scale: 1.15, color: accent)
            _ = uiCanvas.text(toast.definition.title, x: x + 16, y: y + 31, scale: 1.7)
            toasts[0].frames += 1
            if toasts[0].frames > 240 { toasts.removeFirst() }
        }
    }

    private func meter(x: Float, y: Float, width: Float, ratio: Float,
                       fill: SIMD4<Float>, label: String) {
        uiCanvas.fillRect(x: x, y: y, width: width, height: 10,
                          color: SIMD4<Float>(0.03, 0.03, 0.04, 0.88))
        uiCanvas.fillRect(x: x + 1, y: y + 1, width: max(0, width - 2) * max(0, min(1, ratio)), height: 8,
                          color: fill)
        if !label.isEmpty {
            _ = uiCanvas.text(label, x: x, y: y - 10, scale: 1,
                              color: SIMD4<Float>(0.94, 0.94, 0.96, 1))
        }
    }

    private func emptyFrame(game: GameCore, target: RenderTarget, timeSec: Double) -> FramePacket {
        let camera = CameraState(viewProj: .identity, invViewProj: .identity, shadowMat: .identity)
        let uniforms = FrameUniforms(time: Float(timeSec), dayLight: 1, gamma: 1, ambient: 1,
                                     fogStart: 0, fogEnd: 1, fogColor: SIMD4<Float>(0.025, 0.045, 0.085, 1),
                                     sunDir: .zero, shadowsOn: false, ultraOn: false)
        var builder = FrameBuilder(camera: camera, uniforms: uniforms)
        appendUI(game: game, target: target, builder: &builder)
        return builder.finish(includeEmptyPasses: false)
    }

    func hasScreen() -> Bool { screenOpen }
    func screenPausesGame() -> Bool { screenOpen }
    func openScreen(_ kind: String, _ data: ScreenData?) {
        if screenOpen, screenKind == "crafting", kind != "crafting" { returnCraftingGrid() }
        if screenOpen, (screenKind == "inventory" || screenKind == "creative"),
           kind != screenKind { returnInventoryCraftingGrid() }
        if screenOpen, screenKind == "enchanting", kind != "enchanting" { returnEnchantingItems() }
        if screenOpen, screenKind == "anvil", kind != "anvil" { returnAnvilItems() }
        if screenOpen, screenKind == "grindstone", kind != "grindstone" { returnGrindstoneItems() }
        if screenOpen, screenKind == "stonecutter", kind != "stonecutter" { returnStonecutterInput() }
        if screenOpen, screenKind == "smithing", kind != "smithing" { returnSmithingItems() }
        if screenOpen, screenKind == "beacon", kind != "beacon" { returnBeaconPayment() }
        if kind == "ender_chest", let player = activeGame?.player {
            let proxy = BlockEntityData(type: "ender_chest", x: 0, y: 0, z: 0)
            proxy.items = player.enderChest
            externalContainerCommit = { [weak player, weak proxy] in
                if let items = proxy?.items { player?.enderChest = items }
            }
            var container = ScreenData()
            container.be = proxy
            container.title = "Ender Chest"
            screenKind = kind; screenData = container; screenOpen = true
        } else {
            screenKind = kind; screenData = data; screenOpen = true
        }
        if kind == "beacon" { beaconPendingPower = data?.be?.primary }
        if kind == "creative" { creativeSearch = ""; creativeScrollRow = 0 }
        if kind == "enchanting", let game = activeGame {
            var shelves = 0
            let x = data?.x ?? 0, y = data?.y ?? 0, z = data?.z ?? 0
            for dz in -2...2 { for dx in -2...2 where abs(dx) == 2 || abs(dz) == 2 {
                for dy in 0...1 where (game.world.getBlock(x + dx, y + dy, z + dz) >> 4) == Int(B.bookshelf) {
                    shelves += 1
                }
            }}
            enchantingBookshelves = min(15, shelves)
            enchantingSeed = (x &* 73428767) ^ (y &* 912931) ^ (z &* 438289)
        }
        if kind == "sign" {
            signLine = 0
            if screenData?.be?.lines == nil { screenData?.be?.lines = ["", "", "", ""] }
        }
    }
    func openTrading(_ villager: Mob) { tradingMob = villager; screenKind = "trading"; screenOpen = true }
    func openVehicleChest(_ kind: String, _ vehicle: Entity) {
        let proxy = BlockEntityData(type: "vehicle_container", x: 0, y: 0, z: 0)
        if let boat = vehicle as? Boat {
            proxy.items = boat.chestItems
            externalContainerCommit = { [weak boat, weak proxy] in
                if let items = proxy?.items { boat?.chestItems = items }
            }
        } else if let minecart = vehicle as? Minecart {
            proxy.items = minecart.chestItems
            externalContainerCommit = { [weak minecart, weak proxy] in
                if let items = proxy?.items { minecart?.chestItems = items }
            }
        } else { return }
        var data = ScreenData()
        data.be = proxy
        data.title = kind.replacingOccurrences(of: "_", with: " ").uppercased()
        screenKind = kind
        screenData = data
        screenOpen = true
    }
    func openChat(_ prefix: String) { screenKind = "chat"; textBuffer = prefix; screenOpen = true }
    func openDeathScreen(_ message: String) { screenKind = "death"; screenMessage = message; screenOpen = true }
    func openPauseScreen() { screenKind = "pause"; screenOpen = true }
    func openTitleScreen() {
        screenKind = "title"; screenOpen = true
        titleWorldSelection = 0; titleWorldOffset = 0; pendingWorldDeleteID = nil
    }
    func closeAllScreens() {
        if screenKind == "crafting" { returnCraftingGrid() }
        if screenKind == "inventory" || screenKind == "creative" { returnInventoryCraftingGrid() }
        if screenKind == "enchanting" { returnEnchantingItems() }
        if screenKind == "anvil" { returnAnvilItems() }
        if screenKind == "grindstone" { returnGrindstoneItems() }
        if screenKind == "stonecutter" { returnStonecutterInput() }
        if screenKind == "smithing" { returnSmithingItems() }
        if screenKind == "beacon" { returnBeaconPayment() }
        externalContainerCommit?()
        externalContainerCommit = nil
        screenOpen = false; textBuffer = ""; screenData = nil; tradingMob = nil
    }
    func screenText(_ text: String) {
        let filtered = text.filter { $0 != "\n" && $0 != "\r" && $0 != "\t" }
        if screenOpen, screenKind == "create_world" {
            if createWorldField == 0, createWorldName.count < 48 {
                createWorldName.append(contentsOf: filtered.prefix(48 - createWorldName.count))
            } else if createWorldField == 1, createWorldSeed.count < 64 {
                createWorldSeed.append(contentsOf: filtered.prefix(64 - createWorldSeed.count))
            }
        } else if screenOpen, screenKind == "creative" {
            if creativeSearch.count < 40 {
                creativeSearch.append(contentsOf: filtered.prefix(40 - creativeSearch.count))
                creativeScrollRow = 0
            }
        } else if screenOpen, screenKind == "anvil" {
            if anvilName.count < 48 { anvilName.append(contentsOf: filtered.prefix(48 - anvilName.count)) }
        } else if screenOpen, screenKind == "multiplayer" {
            multiplayerMessage = ""
            if multiplayerField == 0, multiplayerAddress.count < 128 {
                multiplayerAddress.append(contentsOf: filtered.prefix(128 - multiplayerAddress.count))
            } else if multiplayerField == 1, multiplayerName.count < 32 {
                multiplayerName.append(contentsOf: filtered.prefix(32 - multiplayerName.count))
            }
        } else if screenOpen, screenKind == "chat", textBuffer.count < 256 {
            textBuffer.append(contentsOf: filtered)
        } else if screenOpen, screenKind == "sign", var lines = screenData?.be?.lines,
                  signLine < lines.count, lines[signLine].count < 30 {
            lines[signLine].append(contentsOf: filtered.prefix(30 - lines[signLine].count))
            screenData?.be?.lines = lines
        }
    }
    func screenKey(_ code: String, game: GameCore) -> Bool {
        guard screenOpen else { return false }
        if screenKind == "title", (code == "ArrowUp" || code == "ArrowDown") {
            let count = game.listWorlds().count
            if count > 0 {
                titleWorldSelection = min(count - 1, max(0, titleWorldSelection + (code == "ArrowUp" ? -1 : 1)))
                pendingWorldDeleteID = nil
            }
            return false
        } else if screenKind == "create_world", code == "Tab" {
            createWorldField = createWorldField == 0 ? 1 : 0
            return false
        } else if screenKind == "create_world", code == "Backspace" {
            if createWorldField == 0, !createWorldName.isEmpty { createWorldName.removeLast() }
            else if createWorldField == 1, !createWorldSeed.isEmpty { createWorldSeed.removeLast() }
            return false
        } else if screenKind == "create_world", code == "Enter" {
            createWorldFromForm(game: game)
            return true
        } else if screenKind == "multiplayer", code == "Tab" {
            multiplayerField = multiplayerField == 0 ? 1 : 0
            return false
        } else if screenKind == "multiplayer", code == "Backspace" {
            multiplayerMessage = ""
            if multiplayerField == 0, !multiplayerAddress.isEmpty { multiplayerAddress.removeLast() }
            else if multiplayerField == 1, !multiplayerName.isEmpty { multiplayerName.removeLast() }
            return false
        } else if screenKind == "multiplayer", code == "Enter" {
            connectFromForm(game: game)
            return !screenOpen
        } else if screenKind == "anvil", code == "Backspace" {
            if !anvilName.isEmpty { anvilName.removeLast() }
            return false
        } else if screenKind == "creative", code == "Backspace" {
            if !creativeSearch.isEmpty { creativeSearch.removeLast(); creativeScrollRow = 0 }
            return false
        } else if screenKind == "title", code == "Enter" {
            let worlds = game.listWorlds()
            if worlds.isEmpty {
                beginCreateWorld(game: game)
                return false
            }
            game.loadWorld(worlds[titleWorldSelection].id)
            closeAllScreens()
            return true
        } else if code == "Backspace", screenKind == "chat", !textBuffer.isEmpty {
            textBuffer.removeLast()
        } else if code == "Backspace", screenKind == "sign", var lines = screenData?.be?.lines,
                  signLine < lines.count, !lines[signLine].isEmpty {
            lines[signLine].removeLast(); screenData?.be?.lines = lines
        } else if code == "Enter", screenKind == "sign" {
            if signLine < 3 { signLine += 1 } else { closeAllScreens(); return true }
        } else if code == "Enter", screenKind == "chat" {
            let message = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty {
                executeGameCommand(game, message, output: pushChat)
            }
            closeAllScreens()
            return true
        }
        return false
    }
    func screenScroll(_ delta: Int) {
        guard screenOpen, delta != 0 else { return }
        if screenKind == "title" {
            titleWorldSelection = max(0, titleWorldSelection + delta)
            pendingWorldDeleteID = nil
        } else if screenKind == "creative" {
            creativeScrollRow = max(0, creativeScrollRow + delta)
        }
    }
    func escapeScreen() -> Bool {
        guard screenOpen, screenKind != "death" else { return false }
        if screenKind == "title" { return true }
        if screenKind == "create_world" { screenKind = "title"; return true }
        if screenKind == "multiplayer" { screenKind = "title"; return true }
        if screenKind == "options" { screenKind = screenReturnKind; return true }
        closeAllScreens()
        return true
    }
    func releasePointer() {}
    func showActionBar(_ text: String, _ time: Int) {
        actionBarText = text
        actionBarFrames = max(1, time * 3)
    }
    func pushChat(_ line: String) {
        chatLines.append(line.replacingOccurrences(of: "§c", with: "").replacingOccurrences(of: "§7", with: ""))
        if chatLines.count > 100 { chatLines.removeFirst(chatLines.count - 100) }
        print(line)
    }
    func pushToast(_ adv: AdvancementDef) {
        toasts.append((adv, 0))
        if toasts.count > 8 { toasts.removeFirst(toasts.count - 8) }
        playUI("ui.toast.challenge_complete")
    }
    func setBossBars(_ bars: [BossBarInfo]) { bossBars = bars }

    func playSound(_ name: String, _ x: Double, _ y: Double, _ z: Double, _ volume: Double, _ pitch: Double) {
        addSubtitle(name)
        if name == "jukebox.stop" { stopDisc(); return }
        if name.hasPrefix("jukebox.play.") {
            playDisc(name, position: SIMD3<Double>(x, y, z), volume: volume)
            return
        }
        let seed = hashString(name)
        let frequency = 120 + Double(seed % 720)
        let waveform: AudioWaveform = name.contains("step") || name.contains("break") ? .noise
            : name.contains("explode") ? .noise : name.contains("hurt") ? .sawtooth : .sine
        let duration = name.contains("explode") ? 0.8 : name.contains("ambient") ? 0.7 : 0.12
        mixer.enqueue(AudioVoice(waveform: waveform,
                                 frequency: frequency * pitch,
                                 endFrequency: name.contains("hurt") ? frequency * pitch * 0.55 : nil,
                                 duration: duration,
                                 volume: min(1, volume) * 0.25, category: "blocks",
                                 spatialPosition: SIMD3<Double>(x, y, z),
                                 maxDistance: name.contains("explode") ? 48 : 18,
                                 reverbSend: name.contains("ambient") ? 0.5 : 0.15))
    }
    func playUI(_ name: String) {
        mixer.enqueue(AudioVoice(waveform: .square, frequency: 640, duration: 0.045,
                                 volume: 0.12, category: "ui"))
    }
    func setAudioEnvironment(_ underwater: Bool, _ caveFactor: Double) {
        mixer.setEnvironment(underwater: underwater, caveFactor: caveFactor)
    }
    func setAudioListener(_ x: Double, _ y: Double, _ z: Double, _ yaw: Double) {
        mixer.setListener(AudioListener(position: SIMD3<Double>(x, y, z), yaw: yaw))
    }
    func tickMusic(_ mood: String, _ enabled: Bool) {
        if !enabled || discPlaying { return }
        if mood != musicMood {
            musicMood = mood
            musicCooldown = 0
        }
        if musicCooldown > 0 {
            musicCooldown -= 1
            return
        }
        let seed = hashString(mood)
        let root: Double
        let waveform: AudioWaveform
        switch mood {
        case "nether": root = 73.42; waveform = .triangle
        case "end": root = 110; waveform = .sine
        case "cave": root = 82.41; waveform = .sine
        case "night": root = 146.83; waveform = .triangle
        default: root = 130.81; waveform = .sine
        }
        let scale = [0, 2, 4, 7, 9, 12]
        for note in 0..<12 {
            let degree = scale[Int((seed &+ UInt32(note * 7)) % UInt32(scale.count))]
            let frequency = root * pow(2, Double(degree) / 12)
            mixer.enqueue(AudioVoice(waveform: waveform, frequency: frequency,
                                     duration: 2.8, attack: 0.35, volume: 0.055,
                                     pan: note.isMultiple(of: 2) ? -0.18 : 0.18,
                                     category: "music", startDelay: Double(note) * 0.72,
                                     reverbSend: 0.7))
            if note.isMultiple(of: 3) {
                mixer.enqueue(AudioVoice(waveform: .sine, frequency: frequency / 2,
                                         duration: 4.2, attack: 0.8, volume: 0.035,
                                         category: "music", startDelay: Double(note) * 0.72,
                                         reverbSend: 0.8))
            }
        }
        musicCooldown = 20 * (32 + Int(seed % 30))
    }
    func stopDisc() {
        if discPlaying { mixer.stopAll() }
        discPlaying = false
        musicCooldown = 100
    }

    private func playDisc(_ name: String, position: SIMD3<Double>, volume: Double) {
        stopDisc()
        discPlaying = true
        let seed = hashString(name)
        let roots: [Double] = [110, 130.81, 146.83, 164.81]
        let root = roots[Int(seed % UInt32(roots.count))]
        let melody = [0, 4, 7, 9, 7, 4, 2, 0, 7, 9, 12, 9, 7, 4, 2, -3]
        for (index, semitone) in melody.enumerated() {
            let frequency = root * pow(2, Double(semitone) / 12)
            let delay = Double(index) * 0.42
            mixer.enqueue(AudioVoice(waveform: .triangle, frequency: frequency,
                                     duration: 0.65, attack: 0.02,
                                     volume: min(1, volume) * 0.12, category: "records",
                                     startDelay: delay, spatialPosition: position,
                                     maxDistance: 56, reverbSend: 0.3))
            if index.isMultiple(of: 4) {
                mixer.enqueue(AudioVoice(waveform: .sine, frequency: root / 2,
                                         duration: 1.4, attack: 0.04,
                                         volume: min(1, volume) * 0.09, category: "records",
                                         startDelay: delay, spatialPosition: position,
                                         maxDistance: 56, reverbSend: 0.25))
            }
        }
    }
    func addParticles(_ type: String, _ x: Double, _ y: Double, _ z: Double, _ count: Int, _ spread: Double, _ cell: Int) {
        spawnParticles(type, x: x, y: y, z: z, count: count, spread: spread, cell: cell)
    }
    func spawnPrecipitation(_ kind: String, _ x: Double, _ y: Double, _ z: Double, _ groundY: Double) {
        spawnParticles(kind, x: x, y: y, z: z, count: 1, spread: 0.15)
    }
}
