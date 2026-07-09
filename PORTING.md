# Pebble Windows/macOS Porting Plan

Status: planning baseline after parallel repository exploration and adversarial review. This is the universal plan for porting Pebble from a macOS AppKit/Metal game to a Windows + macOS codebase while keeping the existing macOS app usable throughout.

## Source facts

- `Package.swift` currently declares `platforms: [.macOS(.v14)]` and has four targets: `PebbleCore`, `Pebble`, `pebsmoke`, and `pebserver`.
- `Sources/Pebble/` is the macOS client: AppKit shell, MTKView frame loop, Metal renderer, AVFoundation audio, ImageIO/CoreGraphics/Compression resource handling, and UI/screens.
- `Sources/PebbleCore/` is mostly headless gameplay/simulation, but it is not fully portable yet: `NetTransport.swift`/`NetSession.swift` use Apple `Network`, `Saves.swift` imports ambient `SQLite3`, `Settings.swift` hard-codes Application Support paths, and `MathX.swift` imports Apple `simd`.
- `pebsmoke` and `goldens/` are the main regression contract. Porting must keep deterministic goldens stable unless a separate gameplay change deliberately updates them.
- The existing macOS Metal app is the release fallback until the new Vulkan path reaches parity.

## External platform decisions

- Swift is officially supported for Windows development/deployment with Windows 10.0 minimum, and SwiftPM supports Windows as a platform: <https://www.swift.org/platform-support/> and <https://docs.swift.org/swiftpm/documentation/packagedescription/platform/>.
- Vulkan on macOS means Vulkan portability through MoltenVK over Metal, not native Vulkan. The macOS Vulkan path must handle portability enumeration and `VK_KHR_portability_subset`: <https://docs.vulkan.org/guide/latest/portability_initiative.html> and <https://github.com/KhronosGroup/MoltenVK/blob/main/Docs/MoltenVK_Runtime_UserGuide.md>.
- Use SDL or an equivalent platform shell for window/input/clipboard/DPI/Vulkan-surface work. SDL Vulkan loader behavior and MoltenVK lookup/bundling must be accounted for: <https://wiki.libsdl.org/SDL2/SDL_Vulkan_LoadLibrary>.
- Prefer a small C/C++ portability layer with a C ABI for Vulkan/SDL/native audio/native sockets/native codecs where needed. Do not make unofficial Swift Vulkan bindings load-bearing.

## Non-negotiable rules

1. Keep the macOS Metal app green until Vulkan is proven.
2. Do not claim Windows support through empty targets, runtime-fatal stubs, broad skips, or blind Windows `swift build`.
3. All CI/smoke runs must use an injected temp data root before constructing `GameCore`, `SaveDB`, settings, or social stores.
4. No unreviewed `PEBBLE_REGOLD=1` in CI.
5. Keep save and network formats stable unless a versioned migration/protocol bump is intentional.
6. Keep simulation deterministic: no platform libm/trig drift in stateful logic, no hash-randomized ordering, no changed tick order, and no background mutation of live world state.
7. Renderer ABI must be documented before Vulkan work: explicit bytes, strides, offsets, uniforms, texture formats, bindings, coordinate conventions, and visual baselines.

## Target architecture

| Layer | Responsibility |
|---|---|
| Portable deterministic core | Simulation, worldgen, registries, entities, systems, items, pure render data, protocol value types. No AppKit/Metal/AVFoundation/Network/SQLite/platform paths. |
| Runtime services | Clocks, executors, entropy, settings store, save store, network services, data roots, host callbacks. Injectable and fakeable. |
| macOS client | Existing AppKit + Metal path, preserved as default macOS release path. |
| Portable client | SDL/native shell + Vulkan backend through C ABI. Windows uses this path; macOS can optionally use Vulkan/MoltenVK. |
| Native portability layer | SDL/window/input/Vulkan/miniaudio/socket/codec glue behind stable C ABI. |
| Tools | `pebsmoke`, `pebserver`, packaging verifiers, and CI jobs. |

## Milestones

1. **M0 Baseline freeze** — record current macOS builds, smoke output, screenshots, and golden status. No regoldening.
2. **M1 Manifest and portable target split** — add truthful Windows-capable portable targets and CI without breaking the macOS app.
3. **M2 Deterministic core purification** — remove platform services from deterministic/runtime code and run deterministic smoke on macOS/Windows.
4. **M3 Persistence, network, and server portability** — injectable data roots, explicit SQLite, socket transport/direct-IP, portable `pebserver`.
5. **M4 Platform services and codecs** — SDL shell, clipboard/dialogs, miniaudio sink, PNG/ZIP adapters, resource pack and skin portability.
6. **M5 Renderer facade and Metal preservation** — backend-neutral frame/resource/capture/stats facade; Metal still default.
7. **M6 Vulkan bootstrap** — Vulkan instance/device/swapchain via C ABI on Windows and macOS MoltenVK with portability handling.
8. **M7 Vulkan world parity** — chunks, shadows, entities, particles, UI, ultra/bloom/composite, capture, screenshot baselines.
9. **M8 Packaging beta** — verified macOS app zip and Windows portable zip with assets, licenses, native deps, and temp-root package smoke.

## Module plan index

| # | Plan | Main dependency |
|---|---|---|
| 01 | [Manifest, Target Split, and CI Build Matrix](PORTING/01-manifest-targets-and-build-matrix.md) | none |
| 02 | [Portable Engine Core and Determinism](PORTING/02-engine-core-determinism.md) | 01 |
| 03 | [Math, SIMD Replacement, Clocks, and Scheduling](PORTING/03-math-simd-and-time.md) | 02 |
| 04 | [Persistence, SQLite, Settings, and User Data Paths](PORTING/04-persistence-data-paths.md) | 01, 02 |
| 05 | [Network Protocol, TCP Transport, Discovery, and Social Connectivity](PORTING/05-network-protocol-and-transport.md) | 01, 04 |
| 06 | [Portable Render Data, Meshes, Atlases, and Shader ABI](PORTING/06-render-data-and-asset-abi.md) | 02, 03 |
| 07 | [Vulkan Renderer Backend and C ABI Portability Layer](PORTING/07-vulkan-backend-and-portability-layer.md) | 06, 09, 11 |
| 08 | [Existing Metal Backend Preservation and Backend Interface](PORTING/08-metal-backend-preservation.md) | 06, 03 |
| 09 | [Window, Input, Clipboard, File Dialogs, and App Shell](PORTING/09-window-input-and-platform-shell.md) | 01, 03 |
| 10 | [Audio Engine Platform Sink](PORTING/10-audio-platform-sink.md) | 09, 04 |
| 11 | [Resource Packs, PNG/Image Codecs, Zip/Archive Codecs, and Skins](PORTING/11-resource-packs-image-archive-codecs.md) | 04, 06, 09 |
| 12 | [Dedicated Server Console, Signals, and Headless Runtime](PORTING/12-server-console-and-headless-runtime.md) | 02, 03, 04, 05 |
| 13 | [Smoke Harness, Goldens, and Cross-Platform CI](PORTING/13-smoke-goldens-and-cross-platform-ci.md) | 01, 02, 04, 05, 12 |
| 14 | [Packaging, Installers, Bundled Assets, and Distribution](PORTING/14-packaging-installers-and-bundled-assets.md) | 01, 09, 11, 12 |

## First execution order

1. 01 → 13 minimal CI skeleton.
2. 02 + 03 deterministic target, math/time/executor seams.
3. 04 data-root/SQLite isolation so tests stop touching real user data.
4. 05 direct TCP transport and temp-root social storage.
5. 12 portable dedicated server, direct-IP smoke.
6. 06 render ABI freeze.
7. 08 Metal facade/preservation.
8. 09 SDL/window/input shell.
9. 11 codecs/resource packs/skins.
10. 10 audio sink.
11. 07 Vulkan backend.
12. 14 packaging.

## Global verification gates

- macOS: app target builds, Metal launch/render smoke works, full smoke stays green.
- Windows: explicit portable targets build; no Apple app/framework sources enter Windows target graph.
- Smoke: required suites run with nonzero check counts and injected temp data root.
- Persistence: settings/keybinds/social/saves/chunk blobs round-trip under a temp root.
- Network: protocol round-trips, malformed-frame behavior, localhost host/guest, direct-IP dedicated server.
- Renderer: ABI layout tests, Metal parity screenshots, Vulkan validation clean smoke, backend-specific screenshot baselines.
- Packaging: no repo resource dependency, correct assets/licenses/native dependency closure, temp-root launch smoke.
