# PebbleRenderABI

Lane D03: the neutral render ABI. Portable Swift types (no Metal, no Vulkan,
no `simd`, no AppKit) describing exactly what `Sources/Pebble/WorldRenderer.swift`
consumes each frame today. This is the contract a Vulkan (or any other)
backend must satisfy byte-for-byte.

Every layout below was read directly out of the current Metal renderer, not
guessed. Where a source line is cited, that is where the layout was derived
from — if a future change to that file changes the layout, this ABI (and
`RenderABI.version`) must be bumped in the same commit.

## Vertex layouts (`RenderABI.swift`)

| ABI type | stride | Metal vertex descriptor | producer |
|---|---|---|---|
| `ChunkVertex` | 28 | `WorldRenderer.swift:293-306` (`chunkVD`) | `PebbleCore/Render/Mesher.swift:95-107` (`MeshBuilder.build()`); documented at `Mesher.swift:5-10` |
| `StarVertex` | 16 | `WorldRenderer.swift:337-344` (`starsVD`) | `WorldRenderer.swift` `buildStars()` |
| `EntityVertex` | 36 | `WorldRenderer.swift:347-360` (`entityVD`) | `PebbleCore/Render/EntityModels.swift:383-386` (`buildEntityGeometry`) |
| `ParticleCornerVertex` (buffer 0, per-vertex) | 8 | `WorldRenderer.swift:364-370` | `Pebble/ParticlesM.swift:42` (`quad` constant) |
| `ParticleInstance` (buffer 1, per-instance) | 48 | `WorldRenderer.swift:371-382` | `Pebble/ParticlesM.swift:322-333` (`render()`) |
| `UIVertex` | 32 | `WorldRenderer.swift:416-426` (`uiVD`) | `Pebble/UICanvas.swift:16` ("pos2 uv2 color4"), pushed at `UICanvas.swift:178-180`, `212-214` |

`ViewmodelVertex` is a `typealias` for `EntityVertex` — the first-person
held-item/bare-arm pass (`Pebble/GearRenderM.swift:281-392`,
`drawFirstPerson`/`submit`) draws through the same `entity_vs`/`entity_fs`
pipeline and the same `ModelGPU` vertex buffers as third-person entities.
There is no separate viewmodel vertex format in the Metal renderer.

The sprite pass (`sprite_vs`, billboarded item icons) has **no vertex
buffer** — its 6 corners are a `constant float2 corners[6]` baked into the
MSL (`Shaders.swift:522`) and positioned entirely from `SpriteUniforms`. Same
for `sky_vs`, `celestial_vs`, `cloud_vs`, `fs_vs` (bloom/composite/title/ultra),
and `logo_vs`: all fullscreen-triangle or procedural-quad passes driven by
`[[vertex_id]]`, not a vertex descriptor. `line_vs` reads a raw
`device packed_float3*` (`Shaders.swift:502`) — data-driven but not a
`MTLVertexDescriptor` layout either. `ShaderManifest.swift` marks all of
these `vertexLayout: .none`.

## Uniform blocks (`Uniforms.swift`)

Every block is `@frozen` and mirrors one `constant` struct in
`Sources/Pebble/Shaders.swift`'s MSL, matching the Swift-side struct that is
actually bound (`WorldRenderer.swift:117-172`, `EntityRendererM.swift:36-49`,
`ParticlesM.swift:25-29`, `UICanvas.swift:10-12`). `float4x4` becomes
`ABIMat4` (4×`SIMD4<Float>` columns, 64 bytes, column-major — bit-identical
to `simd_float4x4`).

| ABI type | bytes | MSL struct | Swift struct |
|---|---|---|---|
| `ChunkSharedUniforms` | 192 | `ChunkShared` (`Shaders.swift:21-28`) | `ChunkSharedU` (`WorldRenderer.swift:117-124`) |
| `UltraUniforms` | 256 | `UltraU` (`Shaders.swift:82-90`) | `UltraUniforms` (`WorldRenderer.swift:125-133`) |
| `SkyUniforms` | 128 | `SkyU` (`Shaders.swift:29-35`) | `SkyUniforms` (`WorldRenderer.swift:134-140`) |
| `CelestialUniforms` | 112 | `CelestialU` (`Shaders.swift:36-41`) | `CelestialUniforms` (`WorldRenderer.swift:141-146`) |
| `StarsUniforms` | 80 | `StarsU` (`Shaders.swift:42-45`) | `StarsUniforms` (`WorldRenderer.swift:147-150`) |
| `CloudUniforms` | 96 | `CloudU` (`Shaders.swift:46-50`) | `CloudUniforms` (`WorldRenderer.swift:151-155`) |
| `LineUniforms` | 80 | `LineU` (`Shaders.swift:65-68`) | `LineUniforms` (`WorldRenderer.swift:156-159`) |
| `SpriteUniforms` | 144 | `SpriteU` (`Shaders.swift:69-76`) | `SpriteUniforms` (`WorldRenderer.swift:160-167`) |
| `CompositeUniforms` | 48 | `CompositeU` (`Shaders.swift:77-81`) | `CompositeUniforms` (`WorldRenderer.swift:168-172`) |
| `EntityUniforms` | 1728 | `EntityU` (`Shaders.swift:51-59`) | `EntityUniforms` (`EntityRendererM.swift:36-49`) |
| `ParticleUniforms` | 96 | `ParticleU` (`Shaders.swift:60-64`) | `ParticleUniforms` (`ParticlesM.swift:25-29`) |
| `UIUniforms` | 16 | `UIU` (`Shaders.swift:91-93`) | `UIUniforms` (`UICanvas.swift:10-12`) |
| `LogoUniforms` | 16 | `LogoU` (`Shaders.swift:556-558`) | bare `SIMD4<Float>` (`WorldRenderer.swift:1219-1221`) |
| `TitleUniforms` | 16 | `constant float4& tu` (`Shaders.swift:575`) | bare `SIMD4<Float>` (`WorldRenderer.swift:1194-1203`) |

`ChunkU` (`Shaders.swift:11-18`), the original non-split chunk uniform
struct, is dead code — nothing in `WorldRenderer.swift` binds it (only the
split `ChunkShared` + a bare per-draw origin `SIMD4<Float>` at buffer index 2
are ever used). It is intentionally **not** mirrored here; mirroring an
unused MSL struct would misrepresent what the renderer actually consumes.

## `FramePacket.swift`

`CameraState` and `FrameUniforms` are **not** a byte-for-byte mirror of one
Metal struct — the real renderer rebuilds `viewProj`/`shadowMat`/time/fog
separately per pass. They collect the fields that recur across
`ChunkSharedUniforms`/`EntityUniforms`/`SpriteUniforms`/`UltraUniforms` so a
future `FrameBuilder` has one canonical source instead of five copies that
can drift. Everything else in this file (handles, `DrawItem`, `RenderPass`)
is new ABI surface with no existing Metal-side counterpart to mirror.

`DrawItem`/`DrawSortKey` define a strict total order (see the doc comments
in `FramePacket.swift`) so draw order is deterministic regardless of
upstream iteration order. This matters because the **current** Metal
renderer iterates `WorldRenderer.sections: [SectionKey: SectionGPU]` — a
plain Swift `Dictionary` — with no `.sorted()` at any of its three call sites
(`WorldRenderer.swift:754`, `888`, `992`). A `FrameBuilder` populating
`FramePacket` from that state must assign real, meaningful sort keys (e.g.
section coordinates) rather than carry the dictionary's incidental order
forward.

## `Capture.swift`

Derived from the only capture path in the renderer:
`Pebble/PhotoBooth.swift` → `WorldRenderer.requestCapture(path:)` →
`WorldRenderer.encodeCapture(_:from:)` (`WorldRenderer.swift:508-537`).

- Source texture: the drawable's color attachment
  (`rpd.colorAttachments[0].texture`, `WorldRenderer.swift:1176`),
  `colorPixelFormat = .bgra8Unorm` (`Pebble/main.swift:418`); the
  `compositePipeline` that renders into it also targets `.bgra8Unorm` (the
  `pipe()` helper's default, `WorldRenderer.swift:309`, used at line `391`).
- Row stride: `destinationBytesPerRow: bpr` where `bpr = w * 4`
  (`WorldRenderer.swift:514, 521`) — tightly packed, no alignment padding.
- Alpha: `CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue`
  (`WorldRenderer.swift:528-529`) — the 4th byte of every pixel is treated as
  unused padding, not as straight or premultiplied alpha. This is safe
  because `composite_fs` always returns `float4(c, 1.0)` (`Shaders.swift:749`)
  — every capture is opaque by construction.
- Origin: no flip is applied anywhere in the capture path, so row 0 of the
  buffer is the top row of the rendered image (top-left origin).

## `ShaderManifest.swift`

One entry per `MTLRenderPipelineState` built in
`WorldRenderer.buildPipelines()` (`WorldRenderer.swift:290-441`), which
constructs every pipeline through a single local closure,
`pipe(vs:fs:vd:blend:additive:color:depth:)` (`WorldRenderer.swift:308-326`).
Each `ShaderPipeline` entry cites the exact `pipe(...)` call site it was read
from (see the comments in `ShaderManifest.swift`). Buffer/texture/sampler
bindings were read off each MSL function's `[[buffer(N)]]` / `[[texture(N)]]`
/ `[[sampler(N)]]` argument attributes in `Shaders.swift`.

24 pipelines total. `opaque` and `cutout` share an identical pipeline
descriptor in the current code (they differ only in the alpha-test threshold
passed through `ChunkSharedUniforms.fog.z` at draw time, not in pipeline
state) — this is existing behavior, reproduced faithfully rather than
"fixed."

## Not guessed / left out

Per the lane brief: nothing in this module was invented to fill a gap.
Anywhere the real layout could not be read directly from the cited source
line, it was left out rather than assumed — see `blocked` in the lane
hand-off for the one such item (the exact runtime `MTLDepthStencilState`
each draw call binds; that is a per-draw-call encoder setting, not part of
any `MTLRenderPipelineDescriptor`, so it is out of scope for a *pipeline*
manifest and was not modeled).
