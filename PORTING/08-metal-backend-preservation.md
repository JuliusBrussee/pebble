# 08 — Existing Metal Backend Preservation and Backend Interface

## Scope

Files: `Sources/Pebble/WorldRenderer.swift`, `Shaders.swift`, `UICanvas.swift`, `EntityRendererM.swift`, `GearRenderM.swift`, `ParticlesM.swift`, `main.swift`, `MathM.swift`.

Goal: keep the macOS Metal app as the default release path while creating the renderer seam needed by Vulkan.

## Current blockers

- `main.swift` owns `MTLCommandBuffer`, drawable, render pass descriptor, presentation, UI flush, and screenshot hooks.
- `WorldRenderer.render` returns/uses Metal command encoders and directly reads `GameCore`/world/settings.
- `UICanvas` owns Metal texture/sampler/buffer state and flushes into `MTLRenderCommandEncoder`.
- `gAppDelegate` couples UI, loading progress, fullscreen, skins, and renderer state.

## Target architecture

- Add `PebbleRenderABI` / renderer facade with no Apple imports.
- App runtime submits full frame/resource/capture/stats requests to a backend.
- Metal backend wraps current `WorldRenderer`, shaders, mesh arena, entity renderer, particles, UI upload, and capture.
- Metal remains `auto` default on macOS.
- Future Vulkan backend registers separately and uses the same facade.

## Plan

1. Freeze Metal baseline: macOS build, smoke, title screenshot, fixed-seed world screenshot, small PhotoBooth subset.
2. Add renderer facade operations: resize, upload/remove/clear meshes, install atlas/assets, tick uploads, spawn/tick particles, request capture, draw title/world frame, stats.
3. Refactor frame ownership: shared runtime builds a CPU UI batch before renderer submission; backend owns command buffers/encoders/present.
4. Split `UICanvas` into CPU batch producer and Metal UI uploader.
5. Convert resource-pack/title/sun/moon/skin/UI assets to plain upload payloads; Metal creates textures internally.
6. Replace `gAppDelegate` production uses with injected services: renderer stats, window actions, UI relayout, skin invalidation, file dialogs.
7. Group Metal-specific code in an Apple-only target/directory with obvious imports/linker settings.
8. Add backend selection: `auto|metal|vulkan`. `vulkan` fails clearly until registered; `metal` unavailable on Windows.
9. Add screenshot/capture harness for title, no-UI world, UI overlay, entities/gear, particles, resource-pack UI/font.

## Verification gates

- `swift build -c release --target Pebble` succeeds.
- Existing macOS app launches title/world/UI.
- No public/shared renderer API exposes `MTL*`, `MTKView`, `CAMetalLayer`, `NSWindow`, or command encoders.
- `UICanvas.flush` is no longer called from shared runtime code.
- `gAppDelegate` has no production references, or remaining shim has owner/removal date.
- Metal screenshots remain within accepted tolerance.
- Capture still preserves current no-UI `PEBBLE_SHOT` behavior; include-UI capture is explicit if added.

## Done criteria

Metal is preserved and isolated behind a real backend interface. Future Vulkan work can proceed without destabilizing macOS release behavior.
