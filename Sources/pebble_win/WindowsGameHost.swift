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
    private let mixer = AudioMixer()
    private var audioOutput: NativeMixerOutput?
    private var sections: [WinSectionKey: WinSectionMeshes] = [:]
    private var screenOpen = false
    private var screenKind = "pause"
    private var textBuffer = ""
    private let uiCanvas = UICanvasCPU(width: 1, height: 1)
    private var uiMesh: MeshHandle?
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

    init(renderer: VulkanRendererBackend, resourcePacks: ResourcePackStack,
         customSkinURL: URL) throws {
        self.renderer = renderer
        self.resourcePacks = resourcePacks
        self.customSkinURL = customSkinURL
        let built = resourcePacks.blockAtlas(fallback: PebbleCore.buildAtlas())
        atlas = try renderer.createTexture(RenderTextureData(
            width: TILE, height: TILE, layers: built.count,
            format: .rgba8Unorm, bytes: built.pixels.flatMap { $0 }))
        try renderer.installAtlas(atlas)
        audioOutput = try? NativeMixerOutput(mixer: mixer)
        try? audioOutput?.start()
    }

    deinit {
        audioOutput?.stop()
        if let uiMesh { renderer.destroyMesh(uiMesh) }
        if let particleMesh { renderer.destroyMesh(particleMesh) }
        for resources in entityResources.values {
            renderer.destroyMesh(resources.mesh)
            renderer.destroyTexture(resources.texture)
        }
        renderer.destroyTexture(atlas)
    }

    func buildFrame(game: GameCore, target: RenderTarget,
                    partial: Double, timeSec: Double) -> FramePacket {
        mixer.setVolumes(master: game.settings.volumes["master"] ?? 0.8,
                         categories: game.settings.volumes.filter { $0.key != "master" })
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
            shadowsOn: shadowsOn, ultraOn: false)
        var builder = FrameBuilder(camera: camera, uniforms: uniforms)
        let shared = ChunkSharedUniforms(
            viewProj: camera.viewProj, shadowMat: camera.shadowMat,
            light: SIMD4<Float>(dayLight, uniforms.gamma, ambient, shadowsOn ? 1 : 0),
            fog: SIMD4<Float>(uniforms.fogStart, uniforms.fogEnd, 0, 1),
            fogColor: fogColor,
            misc: SIMD4<Float>(Float(timeSec), game.settings.clouds ? 1 : 0,
                               Float(world.dim.rawValue), world.raining ? 1 : 0))
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
        appendEntities(game: game, cameraPosition: SIMD3<Double>(cam.x, cam.y, cam.z),
                       partial: partial, uniforms: uniforms, builder: &builder)
        appendParticles(cameraPosition: SIMD3<Double>(cam.x, cam.y, cam.z),
                        viewProjection: camera.viewProj, right: right, up: cameraUp,
                        dayLight: dayLight, timeSec: timeSec, builder: &builder)
        appendViewmodel(game: game, direction: direction, right: right, up: cameraUp,
                        uniforms: uniforms, partial: partial, builder: &builder)
        appendUI(game: game, target: target, builder: &builder)
        return builder.finish(includeEmptyPasses: false)
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

    private func appendParticles(cameraPosition: SIMD3<Double>, viewProjection: ABIMat4,
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
        guard !particles.isEmpty else { return }
        let corners: [Float] = [-1, -1, 1, -1, 1, 1, -1, -1, 1, 1, -1, 1]
        var instances: [ParticleInstance] = []
        instances.reserveCapacity(particles.count)
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
            } else if screenKind == "options" {
                appendOptionsScreen(game: game, width: width, height: height)
            } else if screenKind == "trading" {
                appendTradingScreen(game: game, width: width, height: height)
            } else if screenKind == "pause" || screenKind == "death" {
                appendActionScreen(game: game, width: width, height: height)
            } else if screenKind == "inventory" || screenKind == "creative" {
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
        let y = height * 0.34
        let rows = [
            "RENDER DISTANCE  \(game.settings.renderDistance)",
            "SHADOWS  \(game.settings.shadows ? "ON" : "OFF")",
            "CLOUDS  \(game.settings.clouds ? "ON" : "OFF")",
            "BRIGHTNESS  \(Int(game.settings.gamma * 100))%",
            "SENSITIVITY  \(Int(game.settings.sensitivity * 100))%",
            "MASTER VOLUME  \(Int((game.settings.volumes["master"] ?? 0.8) * 100))%",
            "MUSIC VOLUME  \(Int((game.settings.volumes["music"] ?? 0.5) * 100))%",
        ]
        for (index, title) in rows.enumerated() {
            actionButton(title, x: x, y: y + Float(index) * 42, width: 380)
        }
        actionButton("DONE", x: x, y: y + Float(rows.count) * 42, width: 380)
    }

    private func appendTitleScreen(game: GameCore, width: Float, height: Float) {
        uiCanvas.gradientRect(x: 0, y: 0, width: width, height: height,
                              top: SIMD4<Float>(0.035, 0.07, 0.13, 1),
                              bottom: SIMD4<Float>(0.12, 0.2, 0.18, 1))
        uiCanvas.textCentered("PEBBLE", centerX: width / 2, y: height * 0.2,
                              scale: 8, color: SIMD4<Float>(0.85, 0.94, 1, 1))
        uiCanvas.textCentered("A BLOCK SURVIVAL WORLD", centerX: width / 2, y: height * 0.2 + 70,
                              scale: 1.8, color: SIMD4<Float>(0.68, 0.76, 0.82, 1))
        let buttonX = width / 2 - 150
        let buttonY = height * 0.48
        let worlds = game.listWorlds()
        actionButton(worlds.isEmpty ? "CREATE WORLD" : "PLAY \(worlds[0].name.uppercased())",
                     x: buttonX, y: buttonY, width: 300)
        actionButton("NEW WORLD", x: buttonX, y: buttonY + 50, width: 300)
        actionButton("OPTIONS", x: buttonX, y: buttonY + 100, width: 300)
        actionButton("QUIT", x: buttonX, y: buttonY + 150, width: 300)
        uiCanvas.textCentered("SDL3 + VULKAN", centerX: width / 2, y: height - 34,
                              scale: 1.2, color: SIMD4<Float>(0.55, 0.62, 0.68, 1))
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
        let panelHeight: Float = 236
        let panelX = (width - panelWidth) / 2
        let panelY = (height - panelHeight) / 2
        uiCanvas.fillRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight,
                          color: SIMD4<Float>(0.1, 0.11, 0.14, 0.97))
        _ = uiCanvas.text(screenKind == "creative" ? "CREATIVE INVENTORY" : "INVENTORY",
                          x: panelX + 14, y: panelY + 12, scale: 1.8)
        let gridX = panelX + 14
        let mainY = panelY + 48
        for row in 0..<3 {
            for column in 0..<9 {
                let inventoryIndex = 9 + row * 9 + column
                inventorySlot(player.inventory[inventoryIndex], x: gridX + Float(column) * slot,
                              y: mainY + Float(row) * slot, selected: false)
            }
        }
        let hotbarY = panelY + 182
        for column in 0..<9 {
            inventorySlot(player.inventory[column], x: gridX + Float(column) * slot,
                          y: hotbarY, selected: column == player.selectedSlot)
        }
        if let carriedStack {
            inventoryItem(carriedStack, x: screenMousePosition.x + 6, y: screenMousePosition.y + 6)
        }
    }

    private func inventorySlot(_ stack: ItemStack?, x: Float, y: Float, selected: Bool) {
        uiCanvas.fillRect(x: x, y: y, width: 38, height: 38,
                          color: selected ? SIMD4<Float>(0.8, 0.82, 0.9, 1)
                                          : SIMD4<Float>(0.025, 0.03, 0.04, 0.95))
        uiCanvas.fillRect(x: x + 2, y: y + 2, width: 34, height: 34,
                          color: SIMD4<Float>(0.16, 0.17, 0.2, 1))
        if let stack { inventoryItem(stack, x: x + 4, y: y + 7) }
    }

    private func inventoryItem(_ stack: ItemStack, x: Float, y: Float) {
        let name = itemName(stack.id).split(separator: "_").map { String($0.prefix(1)) }.joined()
        _ = uiCanvas.text(String(name.prefix(4)), x: x, y: y, scale: 1.3,
                          color: stack.ench.isEmpty ? SIMD4<Float>(0.92, 0.93, 0.96, 1)
                                                   : SIMD4<Float>(0.72, 0.5, 1, 1))
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
        let buttonX = lastScreenSize.x / 2 - 150
        let buttonY = lastScreenSize.y * 0.48
        guard x >= buttonX && x < buttonX + 300 else { return }
        if y >= buttonY && y < buttonY + 34 {
            if let first = game.listWorlds().first { game.loadWorld(first.id) }
            else { game.createWorld(name: "World", seedText: "", mode: 0, difficulty: 2) }
            closeAllScreens()
        } else if y >= buttonY + 50 && y < buttonY + 84 {
            let number = game.listWorlds().count + 1
            game.createWorld(name: "World \(number)", seedText: "", mode: 0, difficulty: 2)
            closeAllScreens()
        } else if y >= buttonY + 100 && y < buttonY + 134 {
            screenReturnKind = "title"; screenKind = "options"
        } else if y >= buttonY + 150 && y < buttonY + 184 {
            exitRequested = true
        }
        playUI("ui.button.click")
    }

    private func handleOptionsClick(game: GameCore) {
        let x = lastScreenSize.x / 2 - 190
        let y = lastScreenSize.y * 0.34
        guard screenMousePosition.x >= x && screenMousePosition.x < x + 380 else { return }
        let localY = screenMousePosition.y - y
        let row = Int(localY / 42)
        guard localY >= 0 else { return }
        switch row {
        case 0: game.settings.renderDistance = game.settings.renderDistance >= 24 ? 4 : game.settings.renderDistance + 2
        case 1: game.settings.shadows.toggle()
        case 2: game.settings.clouds.toggle()
        case 3: game.settings.gamma = game.settings.gamma >= 1 ? 0 : min(1, game.settings.gamma + 0.2)
        case 4: game.settings.sensitivity = game.settings.sensitivity >= 1 ? 0.1 : min(1, game.settings.sensitivity + 0.1)
        case 5:
            let value = game.settings.volumes["master"] ?? 0.8
            game.settings.volumes["master"] = value >= 1 ? 0 : min(1, value + 0.1)
        case 6:
            let value = game.settings.volumes["music"] ?? 0.5
            game.settings.volumes["music"] = value >= 1 ? 0 : min(1, value + 0.1)
        case 7:
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
                let name = itemName(stack.id).split(separator: "_").first.map(String.init) ?? "?"
                _ = uiCanvas.text(String(name.prefix(3)), x: x + 5, y: top + 8, scale: 1.25,
                                  color: stack.ench.isEmpty ? SIMD4<Float>(0.88, 0.9, 0.94, 1)
                                                           : SIMD4<Float>(0.72, 0.5, 1, 1))
                if stack.count > 1 {
                    _ = uiCanvas.text("\(stack.count)", x: x + 21, y: top + 24, scale: 1,
                                      color: SIMD4<Float>(1, 1, 1, 1))
                }
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
        screenKind = kind; screenData = data; screenOpen = true
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
    func openTitleScreen() { screenKind = "title"; screenOpen = true }
    func closeAllScreens() {
        externalContainerCommit?()
        externalContainerCommit = nil
        screenOpen = false; textBuffer = ""; screenData = nil; tradingMob = nil
    }
    func screenText(_ text: String) {
        guard screenOpen, screenKind == "chat", textBuffer.count < 256 else { return }
        textBuffer.append(contentsOf: text.filter { $0 != "\n" && $0 != "\r" && $0 != "\t" })
    }
    func screenKey(_ code: String, game: GameCore) -> Bool {
        guard screenOpen else { return false }
        if code == "Backspace", screenKind == "chat", !textBuffer.isEmpty {
            textBuffer.removeLast()
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
    func escapeScreen() -> Bool {
        guard screenOpen, screenKind != "death" else { return false }
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
