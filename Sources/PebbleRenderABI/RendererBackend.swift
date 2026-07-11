public enum IndexFormat: UInt32, Sendable, Equatable {
    case uint16
    case uint32
}

public struct RenderMeshData: Sendable {
    public var vertexLayout: VertexLayoutID
    public var vertexBytes: [UInt8]
    public var indexBytes: [UInt8]
    public var indexFormat: IndexFormat

    public init(vertexLayout: VertexLayoutID, vertexBytes: [UInt8],
                indexBytes: [UInt8] = [], indexFormat: IndexFormat = .uint32) {
        self.vertexLayout = vertexLayout
        self.vertexBytes = vertexBytes
        self.indexBytes = indexBytes
        self.indexFormat = indexFormat
    }
}

public enum RenderTextureFormat: UInt32, Sendable, Equatable {
    case rgba8Unorm
    case bgra8Unorm
    case rgba16Float
    case depth32Float
}

public struct RenderTextureData: Sendable {
    public var width: Int
    public var height: Int
    public var layers: Int
    public var format: RenderTextureFormat
    public var bytes: [UInt8]

    public init(width: Int, height: Int, layers: Int = 1,
                format: RenderTextureFormat = .rgba8Unorm, bytes: [UInt8]) {
        precondition(width > 0 && height > 0 && layers > 0)
        self.width = width
        self.height = height
        self.layers = layers
        self.format = format
        self.bytes = bytes
    }
}

public struct RenderTarget: Sendable {
    public var width: Int
    public var height: Int
    public var scale: Float

    public init(width: Int, height: Int, scale: Float = 1) {
        self.width = width
        self.height = height
        self.scale = scale
    }
}

/// Backend ownership boundary. Handles remain backend-local; frame packets
/// contain only copied values and stable opaque IDs.
public protocol RendererBackend: AnyObject {
    var name: String { get }
    func createMesh(_ data: RenderMeshData) throws -> MeshHandle
    func updateMesh(_ handle: MeshHandle, data: RenderMeshData) throws
    func destroyMesh(_ handle: MeshHandle)
    func createTexture(_ data: RenderTextureData) throws -> TextureHandle
    func updateTexture(_ handle: TextureHandle, data: RenderTextureData) throws
    func destroyTexture(_ handle: TextureHandle)
    func render(_ frame: FramePacket, target: RenderTarget) throws
    func waitUntilIdle()
}

public enum RendererBackendError: Error, Equatable {
    case invalidHandle(UInt32)
    case unsupportedPipeline(UInt32)
    case invalidResource(String)
    case unavailable(String)
}
