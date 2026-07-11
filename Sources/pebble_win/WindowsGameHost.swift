import Foundation
import PebbleAudioCore
import PebbleCore
import PebbleRenderABI
import PebbleRendererVulkan
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

final class WindowsGameHost: GameHost {
    let renderer: VulkanRendererBackend
    let atlas: TextureHandle
    private let mixer = AudioMixer()
    private var audioOutput: NativeMixerOutput?
    private var sections: [WinSectionKey: WinSectionMeshes] = [:]
    private var screenOpen = false
    private let uiCanvas = UICanvasCPU(width: 1, height: 1)
    private var uiMesh: MeshHandle?

    init(renderer: VulkanRendererBackend) throws {
        self.renderer = renderer
        let built = PebbleCore.buildAtlas()
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
        renderer.destroyTexture(atlas)
    }

    func buildFrame(game: GameCore, target: RenderTarget,
                    partial: Double, timeSec: Double) -> FramePacket {
        guard game.hasWorld() else {
            return emptyFrame(target: target, timeSec: timeSec)
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
            fogColor: fogColor, misc: SIMD4<Float>(Float(timeSec), 0, 0, 0))
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

    private func appendUI(game: GameCore, target: RenderTarget, builder: inout FrameBuilder) {
        let width = Float(target.width), height = Float(target.height)
        uiCanvas.begin(width: width, height: height)
        if screenOpen {
            uiCanvas.fillRect(x: 0, y: 0, width: width, height: height,
                              color: SIMD4<Float>(0, 0, 0, 0.58))
            uiCanvas.textCentered("GAME PAUSED", centerX: width / 2, y: height / 2 - 36,
                                  scale: 4, color: SIMD4<Float>(1, 1, 1, 1))
            uiCanvas.textCentered("PRESS ESCAPE TO RESUME", centerX: width / 2, y: height / 2 + 20,
                                  scale: 2, color: SIMD4<Float>(0.75, 0.78, 0.82, 1))
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

    private func emptyFrame(target: RenderTarget, timeSec: Double) -> FramePacket {
        let camera = CameraState(viewProj: .identity, invViewProj: .identity, shadowMat: .identity)
        let uniforms = FrameUniforms(time: Float(timeSec), dayLight: 1, gamma: 1, ambient: 1,
                                     fogStart: 0, fogEnd: 1, fogColor: SIMD4<Float>(0.025, 0.045, 0.085, 1),
                                     sunDir: .zero, shadowsOn: false, ultraOn: false)
        return FrameBuilder(camera: camera, uniforms: uniforms).finish(includeEmptyPasses: false)
    }

    func hasScreen() -> Bool { screenOpen }
    func screenPausesGame() -> Bool { screenOpen }
    func openScreen(_ kind: String, _ data: ScreenData?) { screenOpen = true }
    func openTrading(_ villager: Mob) { screenOpen = true }
    func openVehicleChest(_ kind: String, _ vehicle: Entity) { screenOpen = true }
    func openChat(_ prefix: String) { screenOpen = true }
    func openDeathScreen(_ message: String) { screenOpen = true }
    func openPauseScreen() { screenOpen = true }
    func openTitleScreen() { screenOpen = true }
    func closeAllScreens() { screenOpen = false }
    func releasePointer() {}
    func showActionBar(_ text: String, _ time: Int) { print(text) }
    func pushChat(_ line: String) { print(line) }
    func pushToast(_ adv: AdvancementDef) {}
    func setBossBars(_ bars: [BossBarInfo]) {}

    func playSound(_ name: String, _ x: Double, _ y: Double, _ z: Double, _ volume: Double, _ pitch: Double) {
        let seed = hashString(name)
        let frequency = 120 + Double(seed % 720)
        mixer.enqueue(AudioVoice(waveform: name.contains("step") ? .noise : .sine,
                                 frequency: frequency * pitch, duration: 0.12,
                                 volume: min(1, volume) * 0.25, category: "blocks",
                                 spatialPosition: SIMD3<Double>(x, y, z)))
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
    func tickMusic(_ mood: String, _ enabled: Bool) {}
    func stopDisc() {}
    func addParticles(_ type: String, _ x: Double, _ y: Double, _ z: Double, _ count: Int, _ spread: Double, _ cell: Int) {}
    func spawnPrecipitation(_ kind: String, _ x: Double, _ y: Double, _ z: Double, _ groundY: Double) {}
}
