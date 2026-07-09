# 03 — Math, SIMD Replacement, Clocks, and Scheduling

## Scope

Files: `Sources/PebbleCore/Core/MathX.swift`, `DetMath.swift`, `RandomX.swift`, `Game/GameCore.swift`, `Sources/Pebble/MathM.swift`, `HudM.swift`, `ScreensM.swift`, `UIManagerM.swift`, `MenusM.swift`.

Goal: remove Apple-only math/time assumptions from portable code and define stable matrix/projection/clock/executor contracts.

## Current blockers

- `MathX.swift` imports Apple `simd` and embeds Metal clip-space matrix/frustum helpers.
- App/UI files use `CACurrentMediaTime` via QuartzCore.
- `GameCore` and profiling use `CFAbsoluteTimeGetCurrent`, `Date()`, and concrete GCD queues.
- `MathX.swift` and `MathM.swift` duplicate matrix/projection concepts.

## Decisions

- Ban `import simd`, `simd_float4x4`, and `simd_*` helpers from portable targets.
- Decide separately whether Swift stdlib `SIMD2/3/4` value types are allowed after Windows CI proof.
- Define a Pebble-owned `Mat4f` with 16 `Float32` values, column-major, 64 bytes, explicit byte encoding.
- Split clocks: monotonic for intervals/frame/UI/profiling, wall clock for save metadata, ID source for world/player IDs.
- Keep renderer-specific Metal/Vulkan projection details behind backend tests.

## Plan

1. Add layout/projection docs and tests before replacing call sites.
2. Add `Mat4f` and vector helpers with tests for identity, multiply, translate, scale, rotate, look-dir, perspective, ortho, inverse if used, and frustum extraction.
3. Remove `import simd` from portable core; keep Metal conversion local to the Metal backend.
4. Consolidate `MathM.swift` onto the shared implementation or an adapter wrapper.
5. Add explicit Metal and Vulkan projection tests: depth 0..1, Y policy, frustum planes, inverse ray reconstruction, packed bytes.
6. Add `GameServices` or equivalent with monotonic clock, wall clock, executors, profiler.
7. Replace `CFAbsoluteTimeGetCurrent`/`Date()` in portable runtime with injected clocks.
8. Replace UI `CACurrentMediaTime` with `UIFrameTime` passed to screens/HUD/UI manager.
9. Replace direct `NSApp.terminate`/platform timing in shared screens with platform services.

## Verification gates

- Static search finds no Apple `simd`, `CFAbsoluteTimeGetCurrent`, or `CACurrentMediaTime` in portable targets.
- Math/fdlibm/random/noise goldens stay unchanged.
- Fake clock tests cover frame accumulation, pause behavior, light budget, UI blink/fade/loading/credits/HUD timers.
- Manual executor tests cover chunk generation publication, mesh requeue, and save retry ordering.
- Metal app still renders with existing projection behavior.

## Done criteria

Portable math/time code is platform-neutral and tested; Metal/Vulkan convention differences are explicit, not accidental.
