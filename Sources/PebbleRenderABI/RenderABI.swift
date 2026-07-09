// The neutral render ABI — describes exactly what the Metal renderer
// consumes each frame, in Swift types that mention no Metal and no Vulkan.
// This is the contract a Vulkan (or any other) backend must satisfy.
// See README.md for the exact Metal source line each layout was derived from.
//
// Nothing in this module imports Metal, MetalKit, simd, AppKit, or QuartzCore.

public enum RenderABI {
    /// bump whenever a struct layout, pipeline binding, or draw-order rule changes
    public static let version: UInt32 = 1
}

// ---------------------------------------------------------------------------
// vertex attribute description
// ---------------------------------------------------------------------------

/// portable vertex/uniform component format — mirrors the subset of
/// MTLVertexFormat actually used by Pebble's shaders today. `uchar4Normalized`
/// and `ushort2` are not used by any struct below (nothing in the current
/// Metal renderer packs vertices that tightly) but are declared because a
/// packed-vertex Vulkan path is expected to want them; do not remove them as
/// "unused" without checking D09+ shader/reflection work first.
public enum VertexFormat: UInt32, Hashable, Sendable {
    case float1
    case float2
    case float3
    case float4
    case uint1
    case ushort2
    case uchar4Normalized

    /// size in bytes of one value of this format
    public var byteSize: Int {
        switch self {
        case .float1: return 4
        case .float2: return 8
        case .float3: return 12
        case .float4: return 16
        case .uint1: return 4
        case .ushort2: return 4
        case .uchar4Normalized: return 4
        }
    }
}

/// one field of a vertex layout: name (documentation only), byte offset
/// within the vertex/element, and format.
public struct VertexAttribute: Hashable, Sendable {
    public let name: String
    public let offset: Int
    public let format: VertexFormat
    public init(name: String, offset: Int, format: VertexFormat) {
        self.name = name
        self.offset = offset
        self.format = format
    }
}

// ---------------------------------------------------------------------------
// chunk vertex — Sources/Pebble/WorldRenderer.swift:293-306 (chunkVD),
// produced by Sources/PebbleCore/Render/Mesher.swift:95-107 (MeshBuilder.build).
// Consumed by chunk_vs / shadow_vs (Sources/Pebble/Shaders.swift:98-103, ChunkVIn).
// ---------------------------------------------------------------------------
@frozen public struct ChunkVertex: Hashable, Sendable {
    public var x: Float, y: Float, z: Float   // section-local position
    public var u: Float, v: Float             // tile-local UV
    /// layer(12) | normal(3) | ao(2) | sky(4) | block(4) | emissive(1)
    public var a: UInt32
    /// tintR(8) | tintG(8) | tintB(8) | anim(3)
    public var b: UInt32

    public init(x: Float, y: Float, z: Float, u: Float, v: Float, a: UInt32, b: UInt32) {
        self.x = x; self.y = y; self.z = z; self.u = u; self.v = v; self.a = a; self.b = b
    }

    public static let stride = 28
    public static let layout: [VertexAttribute] = [
        VertexAttribute(name: "position", offset: 0, format: .float3),
        VertexAttribute(name: "uv", offset: 12, format: .float2),
        VertexAttribute(name: "packedA", offset: 20, format: .uint1),
        VertexAttribute(name: "packedB", offset: 24, format: .uint1),
    ]
}

// ---------------------------------------------------------------------------
// star vertex — Sources/Pebble/WorldRenderer.swift:337-344 (starsVD).
// Consumed by stars_vs (Shaders.swift:361-364, StarVIn).
// ---------------------------------------------------------------------------
@frozen public struct StarVertex: Hashable, Sendable {
    public var x: Float, y: Float, z: Float   // unit direction, scaled ×900 in-shader
    public var mag: Float                      // magnitude → point size + twinkle rate

    public init(x: Float, y: Float, z: Float, mag: Float) {
        self.x = x; self.y = y; self.z = z; self.mag = mag
    }

    public static let stride = 16
    public static let layout: [VertexAttribute] = [
        VertexAttribute(name: "position", offset: 0, format: .float3),
        VertexAttribute(name: "magnitude", offset: 12, format: .float1),
    ]
}

// ---------------------------------------------------------------------------
// entity vertex — Sources/Pebble/WorldRenderer.swift:347-360 (entityVD),
// produced by Sources/PebbleCore/Render/EntityModels.swift:383-386
// (buildEntityGeometry appends pos.xyz, normal.xyz, uv.xy, part).
// Consumed by entity_vs (Shaders.swift:415-420, EntityVIn).
//
// Also the first-person "viewmodel" vertex layout: GearRenderM.swift's
// drawFirstPerson()/submit() (Sources/Pebble/GearRenderM.swift:281-392) draws
// the held-item/bare-arm model through the same entity_vs/entity_fs pipeline
// and the same ModelGPU vertex buffers as third-person entities — there is
// no separate viewmodel vertex format in the Metal renderer.
// ---------------------------------------------------------------------------
@frozen public struct EntityVertex: Hashable, Sendable {
    public var x: Float, y: Float, z: Float          // model-space position
    public var nx: Float, ny: Float, nz: Float        // model-space normal
    public var u: Float, v: Float                     // texture UV
    public var part: Float                            // index into the 24-slot pose-matrix array

    public init(x: Float, y: Float, z: Float, nx: Float, ny: Float, nz: Float, u: Float, v: Float, part: Float) {
        self.x = x; self.y = y; self.z = z
        self.nx = nx; self.ny = ny; self.nz = nz
        self.u = u; self.v = v; self.part = part
    }

    public static let stride = 36
    public static let layout: [VertexAttribute] = [
        VertexAttribute(name: "position", offset: 0, format: .float3),
        VertexAttribute(name: "normal", offset: 12, format: .float3),
        VertexAttribute(name: "uv", offset: 24, format: .float2),
        VertexAttribute(name: "part", offset: 32, format: .float1),
    ]
}

/// the viewmodel pass has no vertex format of its own — see EntityVertex doc above.
public typealias ViewmodelVertex = EntityVertex

// ---------------------------------------------------------------------------
// particle vertices — two vertex buffers, Sources/Pebble/WorldRenderer.swift:
// 364-382 (particleVD). Buffer 0 is a shared per-vertex unit quad (6 verts,
// step function = perVertex, the Metal default); buffer 1 is one per-instance
// record per particle, written in Sources/Pebble/ParticlesM.swift:322-333.
// Consumed by particle_vs (Shaders.swift:462-468, ParticleVIn).
// ---------------------------------------------------------------------------
@frozen public struct ParticleCornerVertex: Hashable, Sendable {
    public var x: Float, y: Float   // unit quad corner, in [-1, 1]

    public init(x: Float, y: Float) { self.x = x; self.y = y }

    public static let stride = 8
    public static let layout: [VertexAttribute] = [
        VertexAttribute(name: "corner", offset: 0, format: .float2),
    ]
}

@frozen public struct ParticleInstance: Hashable, Sendable {
    public var x: Float, y: Float, z: Float             // camera-relative world position
    public var u0: Float, v0: Float, u1: Float, v1: Float  // atlas UV rect
    /// floor(layerSize / 256) = atlas array layer; fmod(layerSize, 256) / 100 = billboard size
    public var layerSize: Float
    public var r: Float, g: Float, b: Float, light: Float

    public init(x: Float, y: Float, z: Float, u0: Float, v0: Float, u1: Float, v1: Float,
                layerSize: Float, r: Float, g: Float, b: Float, light: Float) {
        self.x = x; self.y = y; self.z = z
        self.u0 = u0; self.v0 = v0; self.u1 = u1; self.v1 = v1
        self.layerSize = layerSize
        self.r = r; self.g = g; self.b = b; self.light = light
    }

    public static let stride = 48
    public static let layout: [VertexAttribute] = [
        VertexAttribute(name: "position", offset: 0, format: .float3),
        VertexAttribute(name: "uvRect", offset: 12, format: .float4),
        VertexAttribute(name: "layerSize", offset: 28, format: .float1),
        VertexAttribute(name: "colorLight", offset: 32, format: .float4),
    ]
}

// ---------------------------------------------------------------------------
// UI vertex — Sources/Pebble/WorldRenderer.swift:416-426 (uiVD), produced by
// Sources/Pebble/UICanvas.swift:16 ("pos2 uv2 color4") and the push()
// helpers at UICanvas.swift:178-180 / 212-214.
// Consumed by ui_vs (Shaders.swift:755-759, UIVIn). This is also the only
// real "quad" vertex buffer in the renderer — the sprite pass (billboarded
// item icons, sprite_vs) has no vertex buffer at all: its 6 corners are a
// `constant float2 corners[6]` baked into the shader and positioned entirely
// from SpriteUniforms (see Uniforms.swift and ShaderManifest.swift).
// ---------------------------------------------------------------------------
@frozen public struct UIVertex: Hashable, Sendable {
    public var x: Float, y: Float       // pixel-space position
    public var u: Float, v: Float       // texture UV
    public var r: Float, g: Float, b: Float, a: Float

    public init(x: Float, y: Float, u: Float, v: Float, r: Float, g: Float, b: Float, a: Float) {
        self.x = x; self.y = y; self.u = u; self.v = v
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static let stride = 32
    public static let layout: [VertexAttribute] = [
        VertexAttribute(name: "position", offset: 0, format: .float2),
        VertexAttribute(name: "uv", offset: 8, format: .float2),
        VertexAttribute(name: "color", offset: 16, format: .float4),
    ]
}
