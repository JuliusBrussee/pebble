# Windows support matrix

A row may only move to "shipped" when a CI job compiles AND runs it on that OS. Nothing here is aspirational — this reflects `.github/workflows/portability.yml` as it exists today, 2026-07-09.

| Capability | macOS | Windows | Status (shipped/experimental/blocked) | Evidence |
|---|---|---|---|---|
| `PebbleCoreBase` (determinism, math, noise, VCK1 codec) | shipped | shipped | shipped | `portability.yml` macOS and Windows jobs both `swift build -c release --target PebbleCoreBase` |
| `CPebblePlatform` (C ABI skeleton, all capability flags 0) | shipped | shipped | shipped | `portability.yml` macOS and Windows jobs both `swift build -c release --target CPebblePlatform` |
| `pebsmoke-deterministic` (deterministic-only smoke) | shipped | shipped | shipped | `portability.yml` macOS and Windows jobs both build and `swift run` it with `--require-suite deterministic` |
| `PebblePlatformNative` (Swift wrapper over `CPebblePlatform`) | shipped | blocked | experimental on macOS, blocked on Windows | macOS job builds it via `--target PebblePlatformNative`; Windows job does not reference it |
| `PebbleRenderABI` | blocked | blocked | blocked (empty placeholder) | Target exists and builds; no render packet types defined yet — lane D has not landed |
| `PebbleCodecs` | blocked | blocked | blocked (empty placeholder) | Target exists and builds; no codec implementation yet — lane E has not landed |
| `PebbleAudioCore` | blocked | blocked | blocked (empty placeholder) | Target exists and builds; no audio implementation yet — lane E has not landed |
| `pebsmoke-portable` (portable smoke harness) | experimental | blocked | experimental on macOS, blocked on Windows | macOS job builds it and runs `--require-suite vck1`; Windows job explicitly does not build it because it depends on `PebbleCore`, which still imports `Network`/`SQLite3` |
| Rendering (Metal) | shipped | blocked | shipped on macOS, blocked on Windows | macOS job builds `Pebble` (AppKit+Metal); no Windows renderer exists |
| Rendering (Vulkan / MoltenVK) | blocked | blocked | blocked | No Vulkan SDK, no MoltenVK, no `glslc`/`glslang`, no `cmake` on the dev machine or in CI; nothing has been compiled or run |
| Audio (AVFoundation) | shipped | blocked | shipped on macOS, blocked on Windows | `Pebble` links `AVFoundation` on macOS only |
| Audio (miniaudio) | blocked | blocked | blocked | Not vendored, not compiled, not run anywhere |
| Resource packs / codecs (PNG/ZIP) | blocked | blocked | blocked | No codec implementation exists in `PebbleCodecs` or elsewhere for portable use |
| Networking (`Network.framework`) | shipped | blocked | shipped on macOS, blocked on Windows | `PebbleCore`/`Pebble` link `Network` on macOS only; no Windows socket transport exists |
| Networking (native sockets via `CPebblePlatform`) | blocked | blocked | blocked | `CPebblePlatform`'s `has_sockets` capability flag is hardcoded `0`; no socket code exists |
| Persistence (SQLite world store) | shipped | blocked | shipped on macOS, blocked on Windows | `PebbleCore`'s `SaveDB` links `SQLite3` on macOS only; no Windows-portable store exists |
| Full app (`Pebble`, AppKit + Metal) | shipped | blocked | shipped on macOS, blocked on Windows | `portability.yml` macOS job builds `Pebble`, `pebserver`, `pebsmoke` at `-c release`; Windows job builds none of them |
| Dedicated server (`pebserver`) | shipped | blocked | shipped on macOS, blocked on Windows | macOS job builds `pebserver`; Windows job does not reference it — depends on `PebbleCore`'s macOS-only networking/persistence |
