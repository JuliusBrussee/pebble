// Uniform buffer layouts — byte-exact mirrors of the `constant` structs in
// Sources/Pebble/Shaders.swift's MSL, matching what Sources/Pebble/
// WorldRenderer.swift / EntityRendererM.swift / ParticlesM.swift / UICanvas.swift
// actually construct and bind. See README.md for file:line derivations.
//
// No `simd` import: a local ABIMat4 stands in for simd_float4x4/Mat4f (both
// are column-major, so this is a bit-for-bit reinterpretation, not a format
// change).

/// column-major 4×4 float matrix, 64 bytes, no padding — matches
/// simd_float4x4 (and PebbleCore's Mat4f) column order exactly.
@frozen public struct ABIMat4: Hashable, Sendable {
    public var c0, c1, c2, c3: SIMD4<Float>

    public init(c0: SIMD4<Float>, c1: SIMD4<Float>, c2: SIMD4<Float>, c3: SIMD4<Float>) {
        self.c0 = c0; self.c1 = c1; self.c2 = c2; self.c3 = c3
    }

    public static let identity = ABIMat4(
        c0: SIMD4<Float>(1, 0, 0, 0), c1: SIMD4<Float>(0, 1, 0, 0),
        c2: SIMD4<Float>(0, 0, 1, 0), c3: SIMD4<Float>(0, 0, 0, 1))

    public static let stride = 64
}

/// chunk_vs/chunk_fs/shadow_vs shared uniforms (buffer index 1) — mirrors
/// `ChunkShared` (Shaders.swift:21-28), bound from `ChunkSharedU`
/// (WorldRenderer.swift:117-124). The per-draw section origin is a bare
/// SIMD4<Float> at buffer index 2 (WorldRenderer.swift chunk_vs call sites);
/// it has no wrapper struct of its own — see ShaderManifest.swift.
@frozen public struct ChunkSharedUniforms: Sendable {
    public var viewProj: ABIMat4
    public var shadowMat: ABIMat4
    public var light: SIMD4<Float>      // dayLight, gamma, ambient, shadowsOn
    public var fog: SIMD4<Float>        // start, end, alphaTest, globalAlpha
    public var fogColor: SIMD4<Float>
    public var misc: SIMD4<Float>       // time, packFluidDamp, ultraOn, shadowTexel

    public init(viewProj: ABIMat4, shadowMat: ABIMat4, light: SIMD4<Float>, fog: SIMD4<Float>,
                fogColor: SIMD4<Float>, misc: SIMD4<Float>) {
        self.viewProj = viewProj; self.shadowMat = shadowMat
        self.light = light; self.fog = fog; self.fogColor = fogColor; self.misc = misc
    }

    public static let stride = 192
}

/// Owned per-draw payload used by FramePacket chunk draws. Backends bind
/// `shared` at buffer 1 and `origin` at vertex buffer 2.
@frozen public struct ChunkDrawConstants: Sendable {
    public var shared: ChunkSharedUniforms
    public var origin: SIMD4<Float>

    public init(shared: ChunkSharedUniforms, origin: SIMD4<Float>) {
        self.shared = shared
        self.origin = origin
    }

    public static let stride = ChunkSharedUniforms.stride + 16
}

/// ultra_fs post pass uniforms (buffer index 1) — mirrors `UltraU`
/// (Shaders.swift:82-90) / `UltraUniforms` (WorldRenderer.swift:125-133).
@frozen public struct UltraUniforms: Sendable {
    public var invViewProj: ABIMat4
    public var viewProj: ABIMat4
    public var shadowMat: ABIMat4
    public var sunDir: SIMD4<Float>     // xyz + dayLight
    public var params: SIMD4<Float>     // time, far, shadowOK, underwater
    public var fogColor: SIMD4<Float>   // rgb + renderDistance(blocks)
    public var texel: SIMD4<Float>      // 1/w, 1/h of the ultra target

    public init(invViewProj: ABIMat4, viewProj: ABIMat4, shadowMat: ABIMat4, sunDir: SIMD4<Float>,
                params: SIMD4<Float>, fogColor: SIMD4<Float>, texel: SIMD4<Float>) {
        self.invViewProj = invViewProj; self.viewProj = viewProj; self.shadowMat = shadowMat
        self.sunDir = sunDir; self.params = params; self.fogColor = fogColor; self.texel = texel
    }

    public static let stride = 256
}

/// sky_vs/sky_fs uniforms (buffer index 1) — mirrors `SkyU` (Shaders.swift:29-35)
/// / `SkyUniforms` (WorldRenderer.swift:134-140).
@frozen public struct SkyUniforms: Sendable {
    public var invViewProj: ABIMat4
    public var zenith: SIMD4<Float>
    public var horizon: SIMD4<Float>
    public var horizonSun: SIMD4<Float>  // rgb + sunGlow
    public var sunDir: SIMD4<Float>      // xyz + void(isEnd)

    public init(invViewProj: ABIMat4, zenith: SIMD4<Float>, horizon: SIMD4<Float>,
                horizonSun: SIMD4<Float>, sunDir: SIMD4<Float>) {
        self.invViewProj = invViewProj; self.zenith = zenith; self.horizon = horizon
        self.horizonSun = horizonSun; self.sunDir = sunDir
    }

    public static let stride = 128
}

/// celestial_vs/celestial_fs uniforms (buffer index 1) — mirrors `CelestialU`
/// (Shaders.swift:36-41) / `CelestialUniforms` (WorldRenderer.swift:141-146).
@frozen public struct CelestialUniforms: Sendable {
    public var viewProj: ABIMat4
    public var center: SIMD4<Float>   // xyz + billboard size
    public var right: SIMD4<Float>    // xyz + texMode
    public var up: SIMD4<Float>       // xyz + moonPhase (<0 = sun)

    public init(viewProj: ABIMat4, center: SIMD4<Float>, right: SIMD4<Float>, up: SIMD4<Float>) {
        self.viewProj = viewProj; self.center = center; self.right = right; self.up = up
    }

    public static let stride = 112
}

/// stars_vs/stars_fs uniforms (buffer index 1) — mirrors `StarsU`
/// (Shaders.swift:42-45) / `StarsUniforms` (WorldRenderer.swift:147-150).
@frozen public struct StarsUniforms: Sendable {
    public var viewProj: ABIMat4
    public var params: SIMD4<Float>   // time, alpha

    public init(viewProj: ABIMat4, params: SIMD4<Float>) {
        self.viewProj = viewProj; self.params = params
    }

    public static let stride = 80
}

/// cloud_vs/cloud_fs uniforms (buffer index 1) — mirrors `CloudU`
/// (Shaders.swift:46-50) / `CloudUniforms` (WorldRenderer.swift:151-155).
@frozen public struct CloudUniforms: Sendable {
    public var viewProj: ABIMat4
    public var offset: SIMD4<Float>   // xyz + scale
    public var scroll: SIMD4<Float>   // sx, sy, brightness, fogEnd

    public init(viewProj: ABIMat4, offset: SIMD4<Float>, scroll: SIMD4<Float>) {
        self.viewProj = viewProj; self.offset = offset; self.scroll = scroll
    }

    public static let stride = 96
}

/// line_vs/line_fs uniforms (buffer index 1) — mirrors `LineU`
/// (Shaders.swift:65-68) / `LineUniforms` (WorldRenderer.swift:156-159).
@frozen public struct LineUniforms: Sendable {
    public var viewProj: ABIMat4
    public var color: SIMD4<Float>

    public init(viewProj: ABIMat4, color: SIMD4<Float>) {
        self.viewProj = viewProj; self.color = color
    }

    public static let stride = 80
}

/// sprite_vs/sprite_fs uniforms (buffer index 1) — mirrors `SpriteU`
/// (Shaders.swift:69-76) / `SpriteUniforms` (WorldRenderer.swift:160-167).
@frozen public struct SpriteUniforms: Sendable {
    public var viewProj: ABIMat4
    public var center: SIMD4<Float>    // xyz + billboard size
    public var right: SIMD4<Float>
    public var uvRect: SIMD4<Float>    // u0 v0 u1 v1
    public var light: SIMD4<Float>     // light, fogStart, fogEnd, _
    public var fogColor: SIMD4<Float>

    public init(viewProj: ABIMat4, center: SIMD4<Float>, right: SIMD4<Float>, uvRect: SIMD4<Float>,
                light: SIMD4<Float>, fogColor: SIMD4<Float>) {
        self.viewProj = viewProj; self.center = center; self.right = right
        self.uvRect = uvRect; self.light = light; self.fogColor = fogColor
    }

    public static let stride = 144
}

/// bloom/ultra blur + composite_fs uniforms (buffer index 1) — mirrors
/// `CompositeU` (Shaders.swift:77-81) / `CompositeUniforms`
/// (WorldRenderer.swift:168-172). `blur_fs`/`ultra_blur_fs` reuse `tint.xy`
/// as the blur direction; only `composite_fs` reads every field.
@frozen public struct CompositeUniforms: Sendable {
    public var params: SIMD4<Float>    // bloomAmt, warp, time, darkness
    public var tint: SIMD4<Float>
    public var params2: SIMD4<Float>   // ultraOn, aoStrength, volStrength, _

    public init(params: SIMD4<Float>, tint: SIMD4<Float>, params2: SIMD4<Float>) {
        self.params = params; self.tint = tint; self.params2 = params2
    }

    public static let stride = 48
}

/// entity_vs/entity_fs uniforms (buffer index 1) — mirrors `EntityU`
/// (Shaders.swift:51-59) / `EntityUniforms` (EntityRendererM.swift:36-49).
/// Also the viewmodel pass's uniform block (GearRenderM.swift:311-329) — see
/// ViewmodelVertex in RenderABI.swift.
@frozen public struct EntityUniforms: Sendable {
    public var viewProj: ABIMat4
    public var model: ABIMat4
    /// 24 pose slots — the ender dragon's rig needs more than the old 16
    public var parts: (ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4,
                        ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4,
                        ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4)
    public var light: SIMD4<Float>      // sky, block, dayLight, gamma
    public var misc: SIMD4<Float>       // ambient, alpha, fogStart, fogEnd
    public var overlay: SIMD4<Float>    // hurt-flash rgba
    public var fogColor: SIMD4<Float>

    public init(viewProj: ABIMat4, model: ABIMat4,
                parts: (ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4,
                        ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4,
                        ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4, ABIMat4),
                light: SIMD4<Float>, misc: SIMD4<Float>, overlay: SIMD4<Float>, fogColor: SIMD4<Float>) {
        self.viewProj = viewProj; self.model = model; self.parts = parts
        self.light = light; self.misc = misc; self.overlay = overlay; self.fogColor = fogColor
    }

    public static let partCount = 24
    public static let stride = 1728
}

/// particle_vs uniforms (buffer index **2** — buffers 0/1 are the two vertex
/// streams; see ParticleCornerVertex/ParticleInstance in RenderABI.swift).
/// Mirrors `ParticleU` (Shaders.swift:60-64) / `ParticleUniforms`
/// (ParticlesM.swift:25-29).
@frozen public struct ParticleUniforms: Sendable {
    public var viewProj: ABIMat4
    public var right: SIMD4<Float>
    public var up: SIMD4<Float>   // xyz + dayLight

    public init(viewProj: ABIMat4, right: SIMD4<Float>, up: SIMD4<Float>) {
        self.viewProj = viewProj; self.right = right; self.up = up
    }

    public static let stride = 96
}

/// ui_vs uniforms (buffer index 1) — mirrors `UIU` (Shaders.swift:91-93) /
/// `UIUniforms` (UICanvas.swift:10-12).
@frozen public struct UIUniforms: Sendable {
    public var screen: SIMD4<Float>   // width, height

    public init(screen: SIMD4<Float>) { self.screen = screen }

    public static let stride = 16
}

/// logo_vs uniform (buffer index 1) — mirrors `LogoU` (Shaders.swift:556-558).
/// Bound as a bare SIMD4<Float> in Swift (WorldRenderer.swift:1219-1221,
/// `setVertexBytes(&lu, length: 16, index: 1)`), not a named struct — this
/// wrapper exists only so the ABI/manifest can name it like every other
/// uniform block.
@frozen public struct LogoUniforms: Sendable {
    public var rect: SIMD4<Float>   // x0, y0, x1, y1 in NDC

    public init(rect: SIMD4<Float>) { self.rect = rect }

    public static let stride = 16
}

/// title_fs uniform (buffer index 1) — the `constant float4& tu` parameter
/// in Shaders.swift:575, bound as a bare SIMD4<Float> in Swift
/// (WorldRenderer.swift:1194-1203, `tu`). Same rationale as LogoUniforms.
@frozen public struct TitleUniforms: Sendable {
    public var uvTransform: SIMD4<Float>   // scale.xy, offset.zw for aspect-fill crop

    public init(uvTransform: SIMD4<Float>) { self.uvTransform = uvTransform }

    public static let stride = 16
}
