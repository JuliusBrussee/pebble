# 02 — Portable Engine Core and Determinism

## Scope

Files: `Sources/PebbleCore/Core/`, `World/`, `Gen/`, `Entity/`, `Items/`, `Systems/`, `Render/Mesher.swift`, and `Game/GameCore.swift` where it touches deterministic runtime behavior.

Goal: keep Pebble's gameplay and world generation bit-stable while platform services are extracted.

## Current blockers

- `GameCore` constructs concrete `SaveDB`, loads settings/keybinds, creates queues, and owns concrete network sessions.
- `PebbleCore` contains Apple `Network`, ambient `SQLite3`, `simd`, wall clocks, and platform data paths.
- Background gen/mesh/save callbacks currently publish through GCD/main-queue patterns that must stay deterministic.

## Target architecture

Split the core into:

- **Deterministic core**: math/RNG/noise, world/chunks/light, worldgen, registries, entities, items, systems, mesher data. No platform services.
- **Runtime orchestration**: `GameCore` with injected services for clock, entropy, executors, settings, saves, network, and host callbacks.
- **Adapters**: macOS/Windows storage, transport, window/audio/renderer outside deterministic core.

## Required service seams

- `EngineClock`: monotonic time for budgets/profiling and wall time for metadata.
- `EngineEntropy`: world IDs, player IDs, new seed defaults; fakeable in tests.
- `EngineExecutors`: sim/main, generation, mesh, save.
- `SettingsStore`, `SaveStore`, `GameNetHost`, `GameNetGuest`.
- `NullHost` / fake host for smoke tests.

## Plan

1. Freeze current macOS smoke/golden status.
2. Move platform-free code into a portable target without changing behavior.
3. Replace direct storage/network construction in `GameCore` with injected protocols.
4. Ensure worker jobs return immutable results and publish to the sim executor in deterministic order.
5. Add a single bootstrap/reset path for registries and global module state.
6. Audit state-affecting randomness: use `RandomX` or injected deterministic streams, never platform RNG.
7. Audit Set/Dictionary iteration where order affects output; sort by stable keys.
8. Add tick-trace tests for `GameCore.frame`, chunk adoption, mesh completion, save retry, net callbacks, and shutdown.

## Verification gates

- Deterministic smoke/goldens pass unchanged on macOS and Windows portable targets.
- No platform imports in deterministic core target.
- Registry fingerprints are unchanged unless a separate reviewed change says otherwise.
- Async completion tests prove out-of-order workers do not change deterministic adoption/order.
- VCK1/chunk codec tests pass once persistence module extracts codec.

## Done criteria

A portable deterministic engine can build and run goldens with fake services, while the existing macOS app still behaves the same.
