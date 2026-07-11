import Foundation
import PebbleRenderABI

final class VulkanResourceTable: @unchecked Sendable {
    private let context: VulkanContext
    private let lock = NSLock()
    private var nextMesh: UInt32 = 1
    private var nextTexture: UInt32 = 1
    private var meshes: [MeshHandle: VulkanMeshResource] = [:]
    private var textures: [TextureHandle: VulkanTextureResource] = [:]

    init(context: VulkanContext) { self.context = context }

    func createMesh(_ data: RenderMeshData) throws -> MeshHandle {
        let stride: UInt32 = data.indexFormat == .uint16 ? 2 : 4
        let resource = try context.makeMesh(vertexBytes: data.vertexBytes,
                                            indexBytes: data.indexBytes,
                                            indexStride: stride)
        return withLock {
            let handle = MeshHandle(raw: nextMesh)
            nextMesh = nextIdentifier(after: nextMesh)
            meshes[handle] = resource
            return handle
        }
    }

    func updateMesh(_ handle: MeshHandle, data: RenderMeshData) throws {
        let resource = withLock { meshes[handle] }
        guard let resource else { throw RendererBackendError.invalidHandle(handle.raw) }
        try resource.update(vertexBytes: data.vertexBytes, indexBytes: data.indexBytes,
                            indexStride: data.indexFormat == .uint16 ? 2 : 4)
    }

    func destroyMesh(_ handle: MeshHandle) { withLock { meshes.removeValue(forKey: handle) } }

    func createTexture(_ data: RenderTextureData) throws -> TextureHandle {
        guard data.format == .rgba8Unorm else {
            throw RendererBackendError.invalidResource("Vulkan upload supports rgba8Unorm source textures")
        }
        let expected = data.width * data.height * data.layers * 4
        guard data.bytes.count == expected else {
            throw RendererBackendError.invalidResource("texture byte count \(data.bytes.count) != \(expected)")
        }
        let resource = try context.makeTextureRGBA8(width: data.width, height: data.height,
                                                    layers: data.layers, bytes: data.bytes)
        return withLock {
            let handle = TextureHandle(raw: nextTexture)
            nextTexture = nextIdentifier(after: nextTexture)
            textures[handle] = resource
            return handle
        }
    }

    func updateTexture(_ handle: TextureHandle, data: RenderTextureData) throws {
        let resource = withLock { textures[handle] }
        guard let resource else { throw RendererBackendError.invalidHandle(handle.raw) }
        guard data.format == .rgba8Unorm,
              data.width == resource.width, data.height == resource.height, data.layers == resource.layers else {
            throw RendererBackendError.invalidResource("texture update dimensions/format changed")
        }
        try resource.update(bytes: data.bytes)
    }

    func destroyTexture(_ handle: TextureHandle) { withLock { textures.removeValue(forKey: handle) } }
    func mesh(_ handle: MeshHandle) -> VulkanMeshResource? { withLock { meshes[handle] } }
    func texture(_ handle: TextureHandle) -> VulkanTextureResource? { withLock { textures[handle] } }

    private func nextIdentifier(after value: UInt32) -> UInt32 {
        let next = value &+ 1
        return next == 0 ? 1 : next
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
