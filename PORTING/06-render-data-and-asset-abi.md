# 06 — Portable Render Data, Meshes, Atlases, and Shader ABI

## Scope

Files: `Sources/PebbleCore/Render/`, `Sources/Pebble/Shaders.swift`, `WorldRenderer.swift`, `EntityRendererM.swift`, `GearRenderM.swift`, `ParticlesM.swift`, `UICanvas.swift`.

Goal: freeze the renderer-facing ABI before writing Vulkan. This module documents and tests the bytes that both Metal and Vulkan backends consume.

## Current blockers

- GPU layout is implicit in Swift/Metal code and MSL structs.
- `WorldRenderer` mixes CPU frame building, Metal resource upload, pass setup, and draw submission.
- `UICanvas`, particles, entities, gear, and resource-pack UI still own Metal buffers/textures.
- Windows render-data tests need target split; pack-dependent goldens need portable codecs.

## ABI to freeze

- Chunk stream: 28 bytes, `float3 pos`, `float2 uv`, packed `UInt32 A/B`, `UInt32` indices.
- Entity/gear stream: 36 bytes, `float3 pos`, `float3 normal`, `float2 uv`, `float part`.
- Particle instance: 48 bytes.
- UI vertex: 32 bytes.
- Stars: 16 bytes.
- Lines/sprites and all uniforms.
- Texture formats: terrain atlas array, icon atlas, entity skins, item icons, UI atlas, pack GUI sheet, sun/moon/title/logo, scene/bloom/ultra/depth/shadow targets.
- Samplers, blend/depth/cull state, binding slots, descriptor mappings, pass inputs, matrix/coordinate conventions, alpha/color-space rules.

## Plan

1. Create `docs/render-abi.md` and `RenderABI` constants as single source of truth.
2. Define explicit little-endian byte encoders or C-compatible structs. Swift `MemoryLayout` may be checked but is not the portable ABI by itself.
3. Make Metal descriptors and binding calls consume/check ABI constants.
4. Add static checks that `Shaders.swift` MSL buffer/texture/sampler indices match ABI constants.
5. Freeze current mesh and atlas outputs with existing goldens.
6. Add new procedural render-data goldens for icons, representative entity geometry, gear/item extrusion, particle batches, and UI batches.
7. Split CPU UI batching from Metal upload.
8. Split particle simulation/instance encoding from Metal ring buffers.
9. Split entity/gear/model/skin/texture payload generation from Metal buffer/texture allocation.
10. Define backend-neutral frame/pass packets for later Metal/Vulkan facades.
11. Document macOS Vulkan as MoltenVK portability so future backend does not assume native Vulkan features.

## Verification gates

- `docs/render-abi.md` covers every stream, uniform, texture, sampler, binding, pass, matrix, and color rule.
- Layout/encoder tests validate exact sizes, offsets, byte order, and packed bytes.
- `Sources/PebbleCore/Render` and portable ABI sources have no Metal/AppKit/Vulkan/SDL imports.
- Existing atlas/mesh goldens pass unchanged.
- Metal descriptors and shaders match ABI constants.
- Metal app still renders title/world/UI after each extraction step.

## Done criteria

A future Vulkan backend can consume documented render packets without reverse-engineering Metal code, and the existing Metal backend is verified against the same ABI.
