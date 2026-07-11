/// Deterministic producer for backend-neutral frame packets. Simulation and UI
/// submit logical draws; backend receives canonical pass and draw ordering.
public struct FrameBuilder: Sendable {
    public var camera: CameraState
    public var uniforms: FrameUniforms

    private var draws: [RenderPass.Kind: [DrawItem]] = [:]
    private var sequences: [RenderPass.Kind: UInt32] = [:]

    public init(camera: CameraState, uniforms: FrameUniforms) {
        self.camera = camera
        self.uniforms = uniforms
    }

    public mutating func addDraw(pass: RenderPass.Kind,
                                 pipeline: PipelineID,
                                 mesh: MeshHandle,
                                 depthBucket: UInt32 = 0,
                                 vertexRange: Range<UInt32> = 0..<0,
                                 indexRange: Range<UInt32> = 0..<0,
                                 instanceRange: Range<UInt32> = 0..<1,
                                 textures: [TextureBinding] = [],
                                 pushConstants: [UInt8] = []) {
        let sequence = sequences[pass, default: 0]
        sequences[pass] = sequence &+ 1
        let key = DrawSortKey(pipeline: pipeline.raw, depthBucket: depthBucket,
                              mesh: mesh.raw, sequence: sequence)
        draws[pass, default: []].append(DrawItem(
            sortKey: key,
            pipeline: pipeline,
            meshHandle: mesh,
            vertexRange: vertexRange,
            indexRange: indexRange,
            instanceRange: instanceRange,
            textureBindings: textures.sorted {
                if $0.index != $1.index { return $0.index < $1.index }
                return $0.texture.raw < $1.texture.raw
            },
            pushConstants: pushConstants
        ))
    }

    /// Back-to-front bucket for translucent geometry. Finite positive distance
    /// maps to descending order while invalid values land in farthest bucket.
    public static func translucentDepthBucket(distanceSquared: Float) -> UInt32 {
        guard distanceSquared.isFinite, distanceSquared >= 0 else { return 0 }
        return ~distanceSquared.bitPattern
    }

    /// Front-to-back bucket for opaque geometry.
    public static func opaqueDepthBucket(distanceSquared: Float) -> UInt32 {
        guard distanceSquared.isFinite, distanceSquared >= 0 else { return UInt32.max }
        return distanceSquared.bitPattern
    }

    public func finish(includeEmptyPasses: Bool = true) -> FramePacket {
        let passes = RenderPass.Kind.allCases.sorted().compactMap { kind -> RenderPass? in
            let sortedDraws = (draws[kind] ?? []).sorted()
            if !includeEmptyPasses && sortedDraws.isEmpty { return nil }
            return RenderPass(kind: kind, draws: sortedDraws)
        }
        return FramePacket(camera: camera, uniforms: uniforms, passes: passes)
    }
}

public enum RenderBytes {
    /// Copies one fixed-layout value into owned bytes for DrawItem.pushConstants.
    public static func copy<T>(_ value: T) -> [UInt8] {
        var value = value
        return withUnsafeBytes(of: &value) { Array($0) }
    }

    public static func copy<T>(_ values: [T]) -> [UInt8] {
        values.withUnsafeBytes { Array($0) }
    }
}
