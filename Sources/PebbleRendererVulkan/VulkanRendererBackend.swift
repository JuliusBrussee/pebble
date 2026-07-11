import Foundation
import CPebbleVulkan
import PebbleRenderABI

private final class VulkanChunkFrameRenderer: @unchecked Sendable {
    private let swapchain: VulkanSwapchain
    private let handle: OpaquePointer
    private var atlasTexture: VulkanTextureResource?
    private var uiTexture: VulkanTextureResource?

    init(swapchain: VulkanSwapchain, vertexSPIRV: Data, fragmentSPIRV: Data) throws {
        self.swapchain = swapchain
        var handle: OpaquePointer?
        let status = vertexSPIRV.withUnsafeBytes { vertex in
            fragmentSPIRV.withUnsafeBytes { fragment in
                pb_vulkan_chunk_renderer_create(
                    swapchain.nativeHandle,
                    vertex.bindMemory(to: UInt8.self).baseAddress, vertex.count,
                    fragment.bindMemory(to: UInt8.self).baseAddress, fragment.count,
                    &handle)
            }
        }
        guard status == PB_VULKAN_OK, let handle else {
            throw VulkanBootstrapError(status: status.rawValue,
                                       message: String(cString: pb_vulkan_last_error()))
        }
        self.handle = handle
    }

    deinit { pb_vulkan_chunk_renderer_destroy(handle) }

    func setAtlas(_ texture: VulkanTextureResource) throws {
        let status = pb_vulkan_chunk_renderer_set_atlas(handle, texture.nativeHandle)
        guard status == PB_VULKAN_OK else { throw error(status) }
        atlasTexture = texture
    }

    func installUI(vertexSPIRV: Data, fragmentSPIRV: Data) throws {
        let status = vertexSPIRV.withUnsafeBytes { vertex in
            fragmentSPIRV.withUnsafeBytes { fragment in
                pb_vulkan_chunk_renderer_install_ui(
                    handle,
                    vertex.bindMemory(to: UInt8.self).baseAddress, vertex.count,
                    fragment.bindMemory(to: UInt8.self).baseAddress, fragment.count)
            }
        }
        guard status == PB_VULKAN_OK else { throw error(status) }
    }

    func installShadow(vertexSPIRV: Data, size: UInt32) throws {
        let status = vertexSPIRV.withUnsafeBytes { vertex in
            pb_vulkan_chunk_renderer_install_shadow(
                handle, vertex.bindMemory(to: UInt8.self).baseAddress, vertex.count, size)
        }
        guard status == PB_VULKAN_OK else { throw error(status) }
    }

    func setUITexture(_ texture: VulkanTextureResource) throws {
        let status = pb_vulkan_chunk_renderer_set_ui_texture(handle, texture.nativeHandle)
        guard status == PB_VULKAN_OK else { throw error(status) }
        uiTexture = texture
    }

    func rebuild() throws {
        let status = pb_vulkan_chunk_renderer_rebuild(handle)
        guard status == PB_VULKAN_OK else { throw error(status) }
    }

    func present(sharedUniforms: [UInt8], draws: [PBVulkanChunkDraw],
                 uiDraws: [PBVulkanUIDraw], clear: SIMD4<Float>) throws -> VulkanPresentResult {
        let status = sharedUniforms.withUnsafeBufferPointer { shared in
            draws.withUnsafeBufferPointer { draws in
                uiDraws.withUnsafeBufferPointer { ui in
                    pb_vulkan_renderer_present_frame(handle, shared.baseAddress, shared.count,
                                                     draws.baseAddress, UInt32(draws.count),
                                                     ui.baseAddress, UInt32(ui.count),
                                                     clear.x, clear.y, clear.z, clear.w)
                }
            }
        }
        if status == PB_VULKAN_OUT_OF_DATE { return .needsResize }
        guard status == PB_VULKAN_OK else { throw error(status) }
        return .presented
    }

    private func error(_ status: PBVulkanStatus) -> VulkanBootstrapError {
        VulkanBootstrapError(status: status.rawValue, message: String(cString: pb_vulkan_last_error()))
    }
}

public final class VulkanRendererBackend: RendererBackend, @unchecked Sendable {
    public let name = "vulkan"
    private let context: VulkanContext
    private let swapchain: VulkanSwapchain
    private let resources: VulkanResourceTable
    private let chunkRenderer: VulkanChunkFrameRenderer
    private var atlasHandle: TextureHandle?
    private var meshLayouts: [MeshHandle: VertexLayoutID] = [:]
    private var targetSize: (width: Int, height: Int)

    public init(context: VulkanContext, swapchain: VulkanSwapchain,
                shaderDirectory: URL, initialTarget: RenderTarget) throws {
        self.context = context
        self.swapchain = swapchain
        resources = VulkanResourceTable(context: context)
        let vertex = try Data(contentsOf: shaderDirectory.appendingPathComponent("chunk.vert.spv"))
        let fragment = try Data(contentsOf: shaderDirectory.appendingPathComponent("chunk.frag.spv"))
        chunkRenderer = try VulkanChunkFrameRenderer(swapchain: swapchain,
                                                     vertexSPIRV: vertex, fragmentSPIRV: fragment)
        let uiVertex = try Data(contentsOf: shaderDirectory.appendingPathComponent("ui.vert.spv"))
        let uiFragment = try Data(contentsOf: shaderDirectory.appendingPathComponent("ui.frag.spv"))
        try chunkRenderer.installUI(vertexSPIRV: uiVertex, fragmentSPIRV: uiFragment)
        let shadowVertex = try Data(contentsOf: shaderDirectory.appendingPathComponent("shadow.vert.spv"))
        try chunkRenderer.installShadow(vertexSPIRV: shadowVertex, size: 2048)
        let whiteHandle = try resources.createTexture(RenderTextureData(
            width: 1, height: 1, format: .rgba8Unorm, bytes: [255, 255, 255, 255]))
        if let white = resources.texture(whiteHandle) { try chunkRenderer.setUITexture(white) }
        targetSize = (initialTarget.width, initialTarget.height)
    }

    public func createMesh(_ data: RenderMeshData) throws -> MeshHandle {
        guard data.vertexLayout == .chunk || data.vertexLayout == .ui else {
            throw RendererBackendError.invalidResource("Vulkan backend supports chunk and UI vertex layouts")
        }
        let handle = try resources.createMesh(data)
        meshLayouts[handle] = data.vertexLayout
        return handle
    }

    public func updateMesh(_ handle: MeshHandle, data: RenderMeshData) throws {
        try resources.updateMesh(handle, data: data)
    }

    public func destroyMesh(_ handle: MeshHandle) {
        meshLayouts.removeValue(forKey: handle)
        resources.destroyMesh(handle)
    }

    public func createTexture(_ data: RenderTextureData) throws -> TextureHandle {
        try resources.createTexture(data)
    }

    public func updateTexture(_ handle: TextureHandle, data: RenderTextureData) throws {
        try resources.updateTexture(handle, data: data)
    }

    public func destroyTexture(_ handle: TextureHandle) {
        if atlasHandle == handle { atlasHandle = nil }
        resources.destroyTexture(handle)
    }

    public func installAtlas(_ handle: TextureHandle) throws {
        guard let texture = resources.texture(handle) else { throw RendererBackendError.invalidHandle(handle.raw) }
        try chunkRenderer.setAtlas(texture)
        atlasHandle = handle
    }

    public func render(_ frame: FramePacket, target: RenderTarget) throws {
        if target.width != targetSize.width || target.height != targetSize.height {
            try swapchain.resize(width: target.width, height: target.height)
            try chunkRenderer.rebuild()
            targetSize = (target.width, target.height)
        }
        guard atlasHandle != nil else {
            throw RendererBackendError.invalidResource("chunk atlas is not installed")
        }
        let chunkDraws = frame.passes.flatMap(\.draws).filter {
            $0.pipeline == .opaque || $0.pipeline == .cutout || $0.pipeline == .translucent
        }
        let uiDraws = frame.passes.flatMap(\.draws).filter { $0.pipeline == .ui }
        let unsupported = frame.passes.flatMap(\.draws).first {
            $0.pipeline != .opaque && $0.pipeline != .cutout &&
            $0.pipeline != .translucent && $0.pipeline != .shadow && $0.pipeline != .ui
        }
        if let unsupported { throw RendererBackendError.unsupportedPipeline(unsupported.pipeline.raw) }

        var rawDraws: [PBVulkanChunkDraw] = []
        rawDraws.reserveCapacity(chunkDraws.count)
        var sharedBytes: [UInt8]?
        for draw in chunkDraws {
            guard let mesh = resources.mesh(draw.meshHandle) else {
                throw RendererBackendError.invalidHandle(draw.meshHandle.raw)
            }
            guard draw.pushConstants.count >= ChunkDrawConstants.stride else {
                throw RendererBackendError.invalidResource("chunk draw constants are truncated")
            }
            if sharedBytes == nil { sharedBytes = Array(draw.pushConstants.prefix(ChunkSharedUniforms.stride)) }
            let originOffset = ChunkSharedUniforms.stride
            let origin = draw.pushConstants.withUnsafeBytes { bytes -> SIMD4<Float> in
                bytes.loadUnaligned(fromByteOffset: originOffset, as: SIMD4<Float>.self)
            }
            var raw = PBVulkanChunkDraw()
            raw.mesh = mesh.nativeHandle
            raw.origin.0 = origin.x; raw.origin.1 = origin.y; raw.origin.2 = origin.z; raw.origin.3 = origin.w
            raw.pipeline = draw.pipeline == .opaque ? 0 : draw.pipeline == .cutout ? 1 : 2
            raw.index_count = UInt32(draw.indexRange.count)
            raw.first_index = draw.indexRange.lowerBound
            raw.vertex_offset = 0
            rawDraws.append(raw)
        }
        var rawUI: [PBVulkanUIDraw] = []
        for draw in uiDraws {
            guard meshLayouts[draw.meshHandle] == .ui,
                  let mesh = resources.mesh(draw.meshHandle) else {
                throw RendererBackendError.invalidHandle(draw.meshHandle.raw)
            }
            var raw = PBVulkanUIDraw()
            raw.mesh = mesh.nativeHandle
            raw.screen.0 = Float(target.width); raw.screen.1 = Float(target.height)
            raw.screen.2 = 0; raw.screen.3 = 0
            raw.vertex_count = UInt32(draw.vertexRange.count)
            raw.first_vertex = draw.vertexRange.lowerBound
            rawUI.append(raw)
        }
        let shared = sharedBytes ?? RenderBytes.copy(ChunkSharedUniforms(
            viewProj: frame.camera.viewProj, shadowMat: frame.camera.shadowMat,
            light: SIMD4<Float>(frame.uniforms.dayLight, frame.uniforms.gamma,
                                frame.uniforms.ambient, frame.uniforms.shadowsOn ? 1 : 0),
            fog: SIMD4<Float>(frame.uniforms.fogStart, frame.uniforms.fogEnd, 0, 1),
            fogColor: frame.uniforms.fogColor,
            misc: SIMD4<Float>(frame.uniforms.time, 0, frame.uniforms.ultraOn ? 1 : 0, 0)))
        let result = try chunkRenderer.present(sharedUniforms: shared, draws: rawDraws, uiDraws: rawUI,
                                               clear: frame.uniforms.fogColor)
        if result == .needsResize {
            try swapchain.resize(width: target.width, height: target.height)
            try chunkRenderer.rebuild()
        }
    }

    public func waitUntilIdle() { context.waitUntilIdle() }
}
