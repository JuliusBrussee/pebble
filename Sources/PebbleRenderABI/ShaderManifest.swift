// Portable description of every render pipeline the Metal renderer builds
// in Sources/Pebble/WorldRenderer.swift's buildPipelines() (lines 290-441),
// wired against the MSL functions in Sources/Pebble/Shaders.swift. This is
// the contract a Vulkan backend has to satisfy: same vertex layout, same
// buffer/texture/sampler slots, same blend/depth state, per named pipeline.
//
// buildPipelines() constructs every MTLRenderPipelineState through one
// local closure, `pipe(vs:fs:vd:blend:additive:color:depth:)`
// (WorldRenderer.swift:308-326); every entry below cites the exact `pipe(...)`
// call site it was read from.

public enum ShaderStage: Hashable, Sendable { case vertex, fragment }

public struct ShaderBinding: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case buffer, texture, sampler }
    public let kind: Kind
    public let index: Int
    public let role: String
    public let stage: ShaderStage

    public init(kind: Kind, index: Int, role: String, stage: ShaderStage) {
        self.kind = kind; self.index = index; self.role = role; self.stage = stage
    }
}

/// portable subset of MTLPixelFormat actually used by a render pipeline's
/// color/depth attachments today.
public enum PixelFormat: Hashable, Sendable {
    case bgra8Unorm
    case rgba16Float
    case depth32Float
    /// pipeline declares no attachment of this kind (`MTLPixelFormat.invalid`
    /// in the current code — e.g. the shadow pass has no color attachment,
    /// and every postprocess pass has no depth attachment).
    case none
}

public enum BlendFactor: Hashable, Sendable {
    case zero, one, sourceAlpha, oneMinusSourceAlpha
}

/// mirrors the four blend factors `pipe()` ever sets (WorldRenderer.swift:
/// 316-322) — every blended pipeline uses `sourceAlpha` / `one` /
/// `oneMinusSourceAlpha` in the same positions; the only thing that varies
/// between pipelines is whether blending is enabled at all, and whether
/// `destinationRGB` is `.one` (additive) or `.oneMinusSourceAlpha` (normal).
public struct BlendState: Hashable, Sendable {
    public var sourceRGB: BlendFactor
    public var destinationRGB: BlendFactor
    public var sourceAlpha: BlendFactor
    public var destinationAlpha: BlendFactor

    public init(sourceRGB: BlendFactor, destinationRGB: BlendFactor,
                sourceAlpha: BlendFactor, destinationAlpha: BlendFactor) {
        self.sourceRGB = sourceRGB; self.destinationRGB = destinationRGB
        self.sourceAlpha = sourceAlpha; self.destinationAlpha = destinationAlpha
    }

    /// the standard (non-additive) alpha blend every `pipe(..., blend: true)`
    /// call uses unless it also passes `additive: true`.
    public static let normalAlpha = BlendState(
        sourceRGB: .sourceAlpha, destinationRGB: .oneMinusSourceAlpha,
        sourceAlpha: .one, destinationAlpha: .oneMinusSourceAlpha)

    /// `pipe(..., blend: true, additive: true)`.
    public static let additive = BlendState(
        sourceRGB: .sourceAlpha, destinationRGB: .one,
        sourceAlpha: .one, destinationAlpha: .oneMinusSourceAlpha)
}

/// which RenderABI vertex struct (if any) a pipeline's vertex buffer(s)
/// follow. `.none` covers both truly vertex-buffer-less pipelines
/// (fullscreen triangles / procedural quads driven by `[[vertex_id]]`) and
/// `line_vs`, which reads a raw `device packed_float3*` with no
/// MTLVertexDescriptor at all.
public enum VertexLayoutID: Hashable, Sendable {
    case chunk
    case star
    case entity
    /// two vertex buffers: ParticleCornerVertex (per-vertex) + ParticleInstance
    /// (per-instance) — see RenderABI.swift.
    case particle
    case ui
    case none
}

public struct ShaderPipeline: Sendable {
    public let id: PipelineID
    public let name: String
    public let vertexFunction: String
    public let fragmentFunction: String?
    public let vertexLayout: VertexLayoutID
    public let colorFormat: PixelFormat
    public let depthFormat: PixelFormat
    public let blend: BlendState?
    public let bindings: [ShaderBinding]

    public init(id: PipelineID, name: String, vertexFunction: String, fragmentFunction: String?,
                vertexLayout: VertexLayoutID, colorFormat: PixelFormat, depthFormat: PixelFormat,
                blend: BlendState?, bindings: [ShaderBinding]) {
        self.id = id; self.name = name; self.vertexFunction = vertexFunction
        self.fragmentFunction = fragmentFunction; self.vertexLayout = vertexLayout
        self.colorFormat = colorFormat; self.depthFormat = depthFormat
        self.blend = blend; self.bindings = bindings
    }
}

/// named constants for every pipeline in ShaderManifest.pipelines, in the
/// same order buildPipelines() creates them.
public extension PipelineID {
    static let opaque = PipelineID(raw: 0)
    static let cutout = PipelineID(raw: 1)
    static let translucent = PipelineID(raw: 2)
    static let shadow = PipelineID(raw: 3)
    static let sky = PipelineID(raw: 4)
    static let celestial = PipelineID(raw: 5)
    static let celestialAdditive = PipelineID(raw: 6)
    static let cloud = PipelineID(raw: 7)
    static let stars = PipelineID(raw: 8)
    static let entity = PipelineID(raw: 9)
    static let entityHDR = PipelineID(raw: 10)
    static let particle = PipelineID(raw: 11)
    static let particleHDR = PipelineID(raw: 12)
    static let line = PipelineID(raw: 13)
    static let sprite = PipelineID(raw: 14)
    static let spriteHDR = PipelineID(raw: 15)
    static let bloomExtract = PipelineID(raw: 16)
    static let blur = PipelineID(raw: 17)
    static let composite = PipelineID(raw: 18)
    static let title = PipelineID(raw: 19)
    static let logo = PipelineID(raw: 20)
    static let ultra = PipelineID(raw: 21)
    static let ultraBlur = PipelineID(raw: 22)
    static let ui = PipelineID(raw: 23)
}

private func vbuf(_ index: Int, _ role: String) -> ShaderBinding {
    ShaderBinding(kind: .buffer, index: index, role: role, stage: .vertex)
}
private func fbuf(_ index: Int, _ role: String) -> ShaderBinding {
    ShaderBinding(kind: .buffer, index: index, role: role, stage: .fragment)
}
private func ftex(_ index: Int, _ role: String) -> ShaderBinding {
    ShaderBinding(kind: .texture, index: index, role: role, stage: .fragment)
}
private func fsamp(_ index: Int, _ role: String) -> ShaderBinding {
    ShaderBinding(kind: .sampler, index: index, role: role, stage: .fragment)
}

public enum ShaderManifest {
    /// buffer 1 in both chunk_vs and chunk_fs is ChunkSharedUniforms; buffer 2
    /// (vertex-only) is a bare per-draw-section-origin SIMD4<Float> — see
    /// ChunkSharedUniforms doc comment in Uniforms.swift.
    private static let chunkBindings: [ShaderBinding] = [
        vbuf(0, "ChunkVertex buffer"),
        vbuf(1, "ChunkSharedUniforms"),
        vbuf(2, "chunkOrigin (raw float4)"),
        fbuf(1, "ChunkSharedUniforms"),
        ftex(0, "atlas (texture2d_array)"),
        ftex(1, "shadowMap (depth2d)"),
        fsamp(0, "atlas sampler"),
        fsamp(1, "shadow sampler"),
    ]

    public static let pipelines: [ShaderPipeline] = [
        // --- chunk / shadow — WorldRenderer.swift:328-331 --------------------
        ShaderPipeline(id: .opaque, name: "opaque", vertexFunction: "chunk_vs", fragmentFunction: "chunk_fs",
                       vertexLayout: .chunk, colorFormat: .bgra8Unorm, depthFormat: .depth32Float,
                       blend: nil, bindings: chunkBindings),
        ShaderPipeline(id: .cutout, name: "cutout", vertexFunction: "chunk_vs", fragmentFunction: "chunk_fs",
                       vertexLayout: .chunk, colorFormat: .bgra8Unorm, depthFormat: .depth32Float,
                       blend: nil, bindings: chunkBindings),
        ShaderPipeline(id: .translucent, name: "translucent", vertexFunction: "chunk_vs", fragmentFunction: "chunk_fs",
                       vertexLayout: .chunk, colorFormat: .bgra8Unorm, depthFormat: .depth32Float,
                       blend: .normalAlpha, bindings: chunkBindings),
        ShaderPipeline(id: .shadow, name: "shadow", vertexFunction: "shadow_vs", fragmentFunction: nil,
                       vertexLayout: .chunk, colorFormat: .none, depthFormat: .depth32Float,
                       blend: nil, bindings: [
                           vbuf(0, "ChunkVertex buffer"), vbuf(1, "ChunkSharedUniforms"),
                           vbuf(2, "chunkOrigin (raw float4)"),
                       ]),

        // --- sky dome + celestials + stars + clouds — WorldRenderer.swift:332-345
        ShaderPipeline(id: .sky, name: "sky", vertexFunction: "sky_vs", fragmentFunction: "sky_fs",
                       vertexLayout: .none, colorFormat: .bgra8Unorm, depthFormat: .depth32Float,
                       blend: nil, bindings: [vbuf(1, "SkyUniforms"), fbuf(1, "SkyUniforms")]),
        ShaderPipeline(id: .celestial, name: "celestial", vertexFunction: "celestial_vs", fragmentFunction: "celestial_fs",
                       vertexLayout: .none, colorFormat: .bgra8Unorm, depthFormat: .depth32Float,
                       blend: .normalAlpha, bindings: [
                           vbuf(1, "CelestialUniforms"), fbuf(1, "CelestialUniforms"),
                           ftex(0, "sun/moon texture"), fsamp(0, "texture sampler"),
                       ]),
        ShaderPipeline(id: .celestialAdditive, name: "celestialAdditive", vertexFunction: "celestial_vs", fragmentFunction: "celestial_fs",
                       vertexLayout: .none, colorFormat: .bgra8Unorm, depthFormat: .depth32Float,
                       blend: .additive, bindings: [
                           vbuf(1, "CelestialUniforms"), fbuf(1, "CelestialUniforms"),
                           ftex(0, "sun/moon texture"), fsamp(0, "texture sampler"),
                       ]),
        ShaderPipeline(id: .cloud, name: "cloud", vertexFunction: "cloud_vs", fragmentFunction: "cloud_fs",
                       vertexLayout: .none, colorFormat: .bgra8Unorm, depthFormat: .depth32Float,
                       blend: .normalAlpha, bindings: [
                           vbuf(1, "CloudUniforms"), fbuf(1, "CloudUniforms"),
                           ftex(0, "cloud noise texture"), fsamp(0, "texture sampler"),
                       ]),
        ShaderPipeline(id: .stars, name: "stars", vertexFunction: "stars_vs", fragmentFunction: "stars_fs",
                       vertexLayout: .star, colorFormat: .bgra8Unorm, depthFormat: .depth32Float,
                       blend: .additive, bindings: [
                           vbuf(0, "StarVertex buffer"), vbuf(1, "StarsUniforms"), fbuf(1, "StarsUniforms"),
                       ]),

        // --- entities (also the viewmodel pass — see ViewmodelVertex) — WorldRenderer.swift:361-362
        ShaderPipeline(id: .entity, name: "entity", vertexFunction: "entity_vs", fragmentFunction: "entity_fs",
                       vertexLayout: .entity, colorFormat: .bgra8Unorm, depthFormat: .depth32Float,
                       blend: .normalAlpha, bindings: [
                           vbuf(0, "EntityVertex buffer"), vbuf(1, "EntityUniforms"), fbuf(1, "EntityUniforms"),
                           ftex(0, "model/skin texture"), fsamp(0, "texture sampler"),
                       ]),
        ShaderPipeline(id: .entityHDR, name: "entityHDR", vertexFunction: "entity_vs", fragmentFunction: "entity_fs",
                       vertexLayout: .entity, colorFormat: .rgba16Float, depthFormat: .depth32Float,
                       blend: .normalAlpha, bindings: [
                           vbuf(0, "EntityVertex buffer"), vbuf(1, "EntityUniforms"), fbuf(1, "EntityUniforms"),
                           ftex(0, "model/skin texture"), fsamp(0, "texture sampler"),
                       ]),

        // --- particles — WorldRenderer.swift:383-384
        ShaderPipeline(id: .particle, name: "particle", vertexFunction: "particle_vs", fragmentFunction: "particle_fs",
                       vertexLayout: .particle, colorFormat: .bgra8Unorm, depthFormat: .depth32Float,
                       blend: .normalAlpha, bindings: [
                           vbuf(0, "ParticleCornerVertex buffer"), vbuf(1, "ParticleInstance buffer"),
                           vbuf(2, "ParticleUniforms"), ftex(0, "atlas (texture2d_array)"), fsamp(0, "atlas sampler"),
                       ]),
        ShaderPipeline(id: .particleHDR, name: "particleHDR", vertexFunction: "particle_vs", fragmentFunction: "particle_fs",
                       vertexLayout: .particle, colorFormat: .rgba16Float, depthFormat: .depth32Float,
                       blend: .normalAlpha, bindings: [
                           vbuf(0, "ParticleCornerVertex buffer"), vbuf(1, "ParticleInstance buffer"),
                           vbuf(2, "ParticleUniforms"), ftex(0, "atlas (texture2d_array)"), fsamp(0, "atlas sampler"),
                       ]),

        // --- lines (selection outline / beams) — WorldRenderer.swift:386
        ShaderPipeline(id: .line, name: "line", vertexFunction: "line_vs", fragmentFunction: "line_fs",
                       vertexLayout: .none, colorFormat: .bgra8Unorm, depthFormat: .depth32Float,
                       blend: .normalAlpha, bindings: [
                           vbuf(0, "linePoints (raw device packed_float3*, no vertex descriptor)"),
                           vbuf(1, "LineUniforms"), fbuf(1, "LineUniforms"),
                       ]),

        // --- item sprites — WorldRenderer.swift:387-388
        ShaderPipeline(id: .sprite, name: "sprite", vertexFunction: "sprite_vs", fragmentFunction: "sprite_fs",
                       vertexLayout: .none, colorFormat: .bgra8Unorm, depthFormat: .depth32Float,
                       blend: .normalAlpha, bindings: [
                           vbuf(1, "SpriteUniforms"), fbuf(1, "SpriteUniforms"),
                           ftex(0, "item icon texture"), fsamp(0, "texture sampler"),
                       ]),
        ShaderPipeline(id: .spriteHDR, name: "spriteHDR", vertexFunction: "sprite_vs", fragmentFunction: "sprite_fs",
                       vertexLayout: .none, colorFormat: .rgba16Float, depthFormat: .depth32Float,
                       blend: .normalAlpha, bindings: [
                           vbuf(1, "SpriteUniforms"), fbuf(1, "SpriteUniforms"),
                           ftex(0, "item icon texture"), fsamp(0, "texture sampler"),
                       ]),

        // --- bloom chain — WorldRenderer.swift:389-390
        ShaderPipeline(id: .bloomExtract, name: "bloomExtract", vertexFunction: "fs_vs", fragmentFunction: "bloom_extract_fs",
                       vertexLayout: .none, colorFormat: .bgra8Unorm, depthFormat: .none,
                       blend: nil, bindings: [ftex(0, "scene color"), fsamp(0, "linear sampler")]),
        ShaderPipeline(id: .blur, name: "blur", vertexFunction: "fs_vs", fragmentFunction: "blur_fs",
                       vertexLayout: .none, colorFormat: .bgra8Unorm, depthFormat: .none,
                       blend: nil, bindings: [
                           fbuf(1, "CompositeUniforms (tint.xy = blur direction)"),
                           ftex(0, "source"), fsamp(0, "linear sampler"),
                       ]),

        // --- composite into the drawable — WorldRenderer.swift:391
        ShaderPipeline(id: .composite, name: "composite", vertexFunction: "fs_vs", fragmentFunction: "composite_fs",
                       vertexLayout: .none, colorFormat: .bgra8Unorm, depthFormat: .none,
                       blend: nil, bindings: [
                           fbuf(1, "CompositeUniforms"),
                           ftex(0, "scene"), ftex(1, "bloom"), ftex(2, "ultra"),
                           fsamp(0, "linear sampler"),
                       ]),

        // --- title screen — WorldRenderer.swift:392-393
        ShaderPipeline(id: .title, name: "title", vertexFunction: "fs_vs", fragmentFunction: "title_fs",
                       vertexLayout: .none, colorFormat: .bgra8Unorm, depthFormat: .none,
                       blend: nil, bindings: [
                           fbuf(1, "TitleUniforms (raw float4 uvTransform)"),
                           ftex(0, "title background photo"), fsamp(0, "linear sampler"),
                       ]),
        ShaderPipeline(id: .logo, name: "logo", vertexFunction: "logo_vs", fragmentFunction: "logo_fs",
                       vertexLayout: .none, colorFormat: .bgra8Unorm, depthFormat: .none,
                       blend: .normalAlpha, bindings: [
                           vbuf(1, "LogoUniforms (raw float4 rect)"),
                           ftex(0, "logo texture"), fsamp(0, "linear sampler"),
                       ]),

        // --- ultra: half-res SSAO + volumetric light — WorldRenderer.swift:413-414
        ShaderPipeline(id: .ultra, name: "ultra", vertexFunction: "fs_vs", fragmentFunction: "ultra_fs",
                       vertexLayout: .none, colorFormat: .rgba16Float, depthFormat: .none,
                       blend: nil, bindings: [
                           fbuf(1, "UltraUniforms"),
                           ftex(0, "scene depth (depth2d)"), ftex(1, "shadowMap (depth2d)"),
                           fsamp(0, "depth sampler"), fsamp(1, "shadow sampler"),
                       ]),
        ShaderPipeline(id: .ultraBlur, name: "ultraBlur", vertexFunction: "fs_vs", fragmentFunction: "ultra_blur_fs",
                       vertexLayout: .none, colorFormat: .rgba16Float, depthFormat: .none,
                       blend: nil, bindings: [
                           fbuf(1, "CompositeUniforms (tint.xy = blur direction)"),
                           ftex(0, "source (rgb=volumetric, a=AO)"), fsamp(0, "linear sampler"),
                       ]),

        // --- UI 2D — WorldRenderer.swift:427
        ShaderPipeline(id: .ui, name: "ui", vertexFunction: "ui_vs", fragmentFunction: "ui_fs",
                       vertexLayout: .ui, colorFormat: .bgra8Unorm, depthFormat: .none,
                       blend: .normalAlpha, bindings: [
                           vbuf(0, "UIVertex buffer"), vbuf(1, "UIUniforms"),
                           ftex(0, "UI atlas"), fsamp(0, "texture sampler"),
                       ]),
    ]
}
