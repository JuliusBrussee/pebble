# 07 — Vulkan Renderer Backend and C ABI Portability Layer

## Scope

Files: `Sources/Pebble/WorldRenderer.swift`, `Shaders.swift`, `UICanvas.swift`, `EntityRendererM.swift`, `GearRenderM.swift`, `ParticlesM.swift`, `PhotoBooth.swift`, `MathM.swift`, plus new native Vulkan/C ABI files.

Goal: add a selectable Vulkan backend for Windows and optional macOS MoltenVK without breaking the macOS Metal default.

## Dependencies

- 06 render ABI and frame/resource packet definitions.
- 08 Metal facade preserving current app.
- 09 SDL/window/surface platform shell.
- 11 portable images/resource packs/capture codecs.
- Shader build/reflection tooling.

## Decisions

- Native Vulkan lives in C/C++ behind a stable C ABI. Swift does not expose `Vk*` handles or rely on community Vulkan wrappers.
- Swift builds backend-neutral `WorldRenderFrame` / upload packets; native backend owns Vulkan instance/device/surface/swapchain/pipelines/descriptors/sync.
- macOS Vulkan uses MoltenVK. It must handle `VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR`, `VK_KHR_portability_enumeration`, and `VK_KHR_portability_subset` where applicable.
- Shaders for Vulkan are canonical GLSL 450 or equivalent compiled offline to SPIR-V, with reflection checked against ABI.

## C ABI shape

Expose opaque handles and POD structs only, for example:

- `pb_renderer_get_abi_version`
- `pb_renderer_create/destroy`
- `pb_renderer_resize`
- `pb_renderer_upload_texture`
- `pb_renderer_upload_section/remove_section/clear_sections`
- `pb_renderer_render_frame`
- `pb_renderer_request_capture`
- `pb_renderer_get_stats`
- `pb_renderer_last_error`

Every shared struct gets version/size checks and Swift/C layout tests.

## Plan

1. Split app targets so Vulkan backend/native target can build without AppKit/Metal app dependencies.
2. Finish renderer facade so app/UI code does not see command buffers/encoders/drawables.
3. Extract `WorldRenderFrame`: camera, uniforms, sorted section draws, entities, gear, sprites, particles, UI batch, capture request.
4. Add native ABI skeleton with version, errors, capabilities, layout tests, and build on macOS/Windows without a GPU.
5. Add shader pipeline: source, offline SPIR-V compile, reflection, CI checks.
6. Vulkan bootstrap: SDL window -> surface -> instance -> device -> swapchain -> clear/present.
7. MoltenVK bootstrap on macOS with portability logging and failure diagnostics.
8. Implement UI/title rendering first.
9. Implement atlas uploads and chunk opaque/cutout passes.
10. Add shadows, translucent, entities/gear, particles, sprites/lines, first-person viewmodel.
11. Add ultra, bloom, composite, UI overlay, capture/readback.
12. Add resource-pack/skin invalidation through neutral handles.
13. Add Windows/macOS backend-specific screenshot baselines.

## Vulkan requirements

- Use validation/debug utils in debug/CI where available.
- Handle swapchain resize, minimize, out-of-date/suboptimal, present mode, and surface format negotiation.
- Use device-local buffers/images with staging uploads.
- Respect non-coherent memory flush/invalidate and alignment.
- Use frame fences/semaphores/command pools and fence-based resource retirement.
- Keep capture row order, format, alpha, and color-space explicit.

## Verification gates

- Vulkan initializes on Windows and macOS MoltenVK.
- macOS logs prove portability enumeration/subset handling.
- Validation layers/sync validation clean for smoke scenes.
- SPIR-V reflection matches ABI docs.
- Title/UI, world chunks, entities/gear, particles/weather, ultra/bloom, capture screenshots pass backend baselines.
- Metal remains default and green on macOS.

## Done criteria

Vulkan can render Pebble scenes on Windows and macOS MoltenVK through the C ABI, with clean validation and no regression to the Metal path.
