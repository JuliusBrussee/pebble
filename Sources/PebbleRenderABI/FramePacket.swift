// The neutral per-frame description a FrameBuilder hands to any renderer
// backend (Metal today, Vulkan later). Opaque handles only — no MTLBuffer,
// no MTLTexture, no VkBuffer, no pointers.
//
// Draw order is load-bearing: unstable draw order between two runs of the
// same frame is the #1 source of golden-screenshot flake. Every DrawItem
// carries a `sortKey`; a correct FrameBuilder always hands each RenderPass's
// `draws` to `.sorted()` (or builds them already sorted) before it reaches a
// backend. See DrawSortKey below for the total-order rule, and
// Suite_RenderABI.swift for the stability/totality checks.

// ---------------------------------------------------------------------------
// opaque handles — indices into backend-owned resource tables, never pointers
// ---------------------------------------------------------------------------

public struct MeshHandle: Hashable, Sendable {
    public let raw: UInt32
    public init(raw: UInt32) { self.raw = raw }
}

public struct TextureHandle: Hashable, Sendable {
    public let raw: UInt32
    public init(raw: UInt32) { self.raw = raw }
}

public struct SamplerHandle: Hashable, Sendable {
    public let raw: UInt32
    public init(raw: UInt32) { self.raw = raw }
}

/// identifies one entry in ShaderManifest.pipelines (see ShaderManifest.swift
/// for the named constants, e.g. `PipelineID.opaque`).
public struct PipelineID: Hashable, Sendable {
    public let raw: UInt32
    public init(raw: UInt32) { self.raw = raw }
}

// ---------------------------------------------------------------------------
// camera / frame-global state
//
// Not a byte-for-byte mirror of a single Metal struct — the real renderer
// rebuilds viewProj/shadowMat/time/fog separately per pass (ChunkShared,
// EntityU, SpriteU, UltraU, ...; see Uniforms.swift). CameraState and
// FrameUniforms collect the fields that recur across those blocks so a
// FrameBuilder has one canonical source to derive every pass's uniform
// buffer from, instead of five copies that can drift out of sync.
// ---------------------------------------------------------------------------

public struct CameraState: Sendable {
    /// camera-relative view-projection: all geometry is submitted with the
    /// camera at the origin (see ChunkVertex/EntityVertex doc comments and
    /// ChunkSharedUniforms.viewProj usage) to avoid large-world float error.
    public var viewProj: ABIMat4
    public var invViewProj: ABIMat4
    /// light-space view-projection for the shadow map pass
    public var shadowMat: ABIMat4

    public init(viewProj: ABIMat4, invViewProj: ABIMat4, shadowMat: ABIMat4) {
        self.viewProj = viewProj; self.invViewProj = invViewProj; self.shadowMat = shadowMat
    }
}

public struct FrameUniforms: Sendable {
    public var time: Float
    public var dayLight: Float
    public var gamma: Float
    public var ambient: Float
    public var fogStart: Float
    public var fogEnd: Float
    public var fogColor: SIMD4<Float>
    public var sunDir: SIMD4<Float>
    public var shadowsOn: Bool
    public var ultraOn: Bool

    public init(time: Float, dayLight: Float, gamma: Float, ambient: Float, fogStart: Float, fogEnd: Float,
                fogColor: SIMD4<Float>, sunDir: SIMD4<Float>, shadowsOn: Bool, ultraOn: Bool) {
        self.time = time; self.dayLight = dayLight; self.gamma = gamma; self.ambient = ambient
        self.fogStart = fogStart; self.fogEnd = fogEnd; self.fogColor = fogColor; self.sunDir = sunDir
        self.shadowsOn = shadowsOn; self.ultraOn = ultraOn
    }
}

// ---------------------------------------------------------------------------
// draw order
// ---------------------------------------------------------------------------

/// total, stable ordering for draw items within one RenderPass.
///
/// `sequence` is a monotonically increasing per-pass counter a FrameBuilder
/// assigns as it emits items (0, 1, 2, ...) — it is always unique within a
/// pass, so no two distinct DrawItems ever compare equal. That makes `<` a
/// strict total order: sorting is deterministic regardless of the order
/// items were appended in, a shuffled array always sorts back to exactly one
/// canonical sequence, and Array.sorted()'s stability (guaranteed by Swift)
/// is never actually needed to break a tie — it is only a safety net.
public struct DrawSortKey: Hashable, Comparable, Sendable {
    public var pipeline: UInt32
    /// caller-defined bucket, e.g. front-to-back depth for opaque geometry or
    /// back-to-front for translucent — the FrameBuilder's responsibility to
    /// fill in correctly; the ABI only guarantees the *ordering* is total.
    public var depthBucket: UInt32
    public var mesh: UInt32
    public var sequence: UInt32

    public init(pipeline: UInt32, depthBucket: UInt32, mesh: UInt32, sequence: UInt32) {
        self.pipeline = pipeline; self.depthBucket = depthBucket; self.mesh = mesh; self.sequence = sequence
    }

    public static func < (lhs: DrawSortKey, rhs: DrawSortKey) -> Bool {
        if lhs.pipeline != rhs.pipeline { return lhs.pipeline < rhs.pipeline }
        if lhs.depthBucket != rhs.depthBucket { return lhs.depthBucket < rhs.depthBucket }
        if lhs.mesh != rhs.mesh { return lhs.mesh < rhs.mesh }
        return lhs.sequence < rhs.sequence
    }
}

public struct TextureBinding: Hashable, Sendable {
    public var index: Int
    public var texture: TextureHandle
    public var sampler: SamplerHandle?

    public init(index: Int, texture: TextureHandle, sampler: SamplerHandle?) {
        self.index = index; self.texture = texture; self.sampler = sampler
    }
}

public struct DrawItem: Hashable, Sendable, Comparable {
    public var sortKey: DrawSortKey
    public var pipeline: PipelineID
    public var meshHandle: MeshHandle
    /// vertex range for non-indexed draws; empty for indexed draws.
    public var vertexRange: Range<UInt32>
    /// index range within the mesh's index buffer; empty for non-indexed draws
    public var indexRange: Range<UInt32>
    /// instance range for instanced draws (e.g. particles); 0..<1 for a single draw
    public var instanceRange: Range<UInt32>
    public var textureBindings: [TextureBinding]
    /// raw bytes for the pass's uniform block (see Uniforms.swift) — never a
    /// pointer, always an owned copy, matching Metal's setVertexBytes/
    /// setFragmentBytes semantics used throughout WorldRenderer.swift today.
    public var pushConstants: [UInt8]

    public init(sortKey: DrawSortKey, pipeline: PipelineID, meshHandle: MeshHandle,
                vertexRange: Range<UInt32> = 0..<0,
                indexRange: Range<UInt32>, instanceRange: Range<UInt32>,
                textureBindings: [TextureBinding], pushConstants: [UInt8]) {
        self.sortKey = sortKey; self.pipeline = pipeline; self.meshHandle = meshHandle
        self.vertexRange = vertexRange
        self.indexRange = indexRange; self.instanceRange = instanceRange
        self.textureBindings = textureBindings; self.pushConstants = pushConstants
    }

    public static func < (lhs: DrawItem, rhs: DrawItem) -> Bool { lhs.sortKey < rhs.sortKey }
}

// ---------------------------------------------------------------------------
// passes / frame
// ---------------------------------------------------------------------------

public struct RenderPass: Sendable {
    /// fixed pass order (declaration order below is the canonical pass
    /// sequence: shadow map, then world/chunks, entities, particles, UI,
    /// postprocess).
    public enum Kind: Int, Hashable, Sendable, CaseIterable, Comparable {
        case shadow, world, entities, particles, ui, postprocess

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var kind: Kind
    /// MUST be in `sortKey` order before a backend consumes it — see the
    /// module doc comment at the top of this file.
    public var draws: [DrawItem]

    public init(kind: Kind, draws: [DrawItem] = []) {
        self.kind = kind; self.draws = draws
    }
}

public struct FramePacket: Sendable {
    public var camera: CameraState
    public var uniforms: FrameUniforms
    /// MUST be in RenderPass.Kind order — the pass sequence is itself part
    /// of the deterministic-order contract, same as DrawItem.sortKey within
    /// a pass.
    public var passes: [RenderPass]

    public init(camera: CameraState, uniforms: FrameUniforms, passes: [RenderPass]) {
        self.camera = camera; self.uniforms = uniforms; self.passes = passes
    }
}
