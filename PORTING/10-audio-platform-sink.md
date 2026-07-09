# 10 — Audio Engine Platform Sink

## Scope

Files: `Sources/Pebble/Audio.swift`, `main.swift`, `HudM.swift`, `Sources/PebbleCore/Game/Settings.swift`.

Goal: preserve Pebble's synthesized audio behavior while replacing AVFoundation with a portable audio service and native miniaudio sink.

## Current blockers

- `Audio.swift` imports AVFoundation and `os`, and mixes recipes, voices, output sink, locks, and settings in one macOS app file.
- App owns concrete `AudioEngineM` and polls volume settings in the draw loop.
- The render callback currently locks, copies Swift arrays, and mutates arrays.
- Full Windows client audio depends on shell/data-root/network target work; start with standalone audio smoke.

## Target architecture

- `PebbleAudio` Swift target: recipes, resolver, mixer, service facade, null/test sink.
- `CPebblePlatform` native target: miniaudio and optional atomic command ring helpers.
- `AudioService` protocol matching current `GameHost` calls: start/stop, volumes, environment, listener, play, playUI, playDisc, stopDisc, tickMusic.
- miniaudio C ABI: create/start/stop/destroy, callback trampoline, error strings, no miniaudio types in gameplay/UI.

## Real-time rules

- Callback must not allocate, log, call UI, do dictionary/string work, or take blocking locks.
- Use fixed POD commands in a bounded SPSC ring: voice, setVolumes, setEnvironment, stopDisc, reset/shutdown.
- Callback owns active voices, category gains, environment state, delay lines.
- Use frame/sample-rate based scheduling, not locked wall-time snapshots.
- Expose overflow counters and explicit drop policy.

## Plan

1. Freeze current behavior and fixtures: UI click, block/entity fallback, positional panning, discs, music, underwater, cave reverb, subtitles.
2. Record a human decision on current jukebox semantics: preserve existing behavior or fix `jukebox.stop`/disc removal to call `stopDisc()`.
3. Add `PebbleAudio` and audio smoke target so tests do not depend on AppKit/Metal.
4. Move recipes/resolver/categories/voice data into `PebbleAudio`.
5. Convert recipe categories from strings to fixed `AudioCategory` enum.
6. Introduce `AudioService` and route `HostBridge` through it.
7. Add immediate settings-to-audio propagation; keep polling only as temporary fallback.
8. Implement command ring and callback-owned mixer.
9. Add miniaudio sink through C ABI and wire macOS first.
10. Remove AVFoundation from default path once miniaudio passes smoke.
11. Wire Windows shell once platform module exists.

## Verification gates

- `PebbleAudio` builds on macOS and Windows with no AVFoundation/AppKit/Metal/QuartzCore/Network imports.
- Offline mixer tests render nonzero output for UI, positional, disc, and music calls.
- Volumes mute/scale categories correctly.
- Subtitle callback fires exactly once for resolved audible recipes according to documented mute behavior.
- Callback steady-state path passes real-time safety review.
- miniaudio start/stop/render smoke passes on macOS and Windows or uses explicit null sink in headless CI.

## Done criteria

Audio recipes and mixer are portable; macOS and Windows can use the same service facade; miniaudio replaces AVFoundation for the portable path without changing gameplay-facing audio APIs.
