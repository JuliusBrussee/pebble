# 01 — Manifest, Target Split, and CI Build Matrix

## Scope

Files: `Package.swift`, `pebble`, `packaging/`, `.github/`, target membership under `Sources/`.

Goal: make the repository truthful about macOS-only and portable targets before any Windows claims. This module should keep the existing macOS `Pebble` app working while introducing real Windows-capable portable targets.

## Current blockers

- `Package.swift` declares only `.macOS(.v14)`.
- `Pebble` links AppKit, Metal, MetalKit, QuartzCore, and AVFoundation unconditionally.
- Full `PebbleCore` cannot honestly be Windows-built yet because it includes `Network.framework`, `SQLite3`, platform paths, clocks, and `simd` assumptions.
- `pebble` is a macOS Bash installer using Xcode tools, `.app`, `codesign`, and `open`.

## Plan

1. Record the current package graph with `swift package describe --type json` and current macOS build/smoke commands.
2. Add explicit products for existing executables and any new portable libraries/smoke tools. Do not rely on synthesized products once splitting begins.
3. Add a real portable deterministic slice first, e.g. `PebbleDeterminism` / `PebbleCoreBase`, containing only source that has no Apple/native dependency.
4. Add a matching deterministic smoke executable. Do not make Windows run full `pebsmoke` until network, persistence, and server seams land.
5. Declare Windows platform intent only for real portable targets, e.g. `.windows(.v10)` after confirming SwiftPM tools support.
6. Keep Apple app sources out of the Windows target graph. Conditional linker settings alone are not enough if sources import AppKit/Metal.
7. Add import/link/symbol hygiene checks for portable targets: no AppKit, Metal, MetalKit, QuartzCore, AVFoundation, Network, SQLite3, ImageIO, CoreGraphics, Compression, Darwin, `CFAbsoluteTimeGetCurrent`, or Application Support paths.
8. Guard `pebble` on non-Darwin with a clear message. Do not add Windows packaging behavior here.
9. Create CI jobs with explicit target commands. No blind Windows `swift build`.
10. Add `docs/PORTING_TARGETS.md` or equivalent target graph docs if implementation needs more detail than this plan.

## CI shape after this module

- macOS: build existing app/core/server/smoke, run current smoke.
- Windows: install/pin Swift, resolve package, build the new portable target, run deterministic smoke subset.
- CI must print Swift version, OS, architecture, and target graph.
- CI must fail if `PEBBLE_REGOLD` is set.

## Verification gates

- `swift package describe --type json` succeeds on macOS and Windows.
- macOS `swift build -c release --target Pebble`, `PebbleCore`, `pebserver`, and `pebsmoke` still work.
- Windows builds at least one real non-empty portable target and matching smoke tool.
- Windows target graph excludes `Sources/Pebble/` AppKit/Metal app sources.
- `pebble` exits clearly on non-macOS.

## Done criteria

The repo has an honest target graph: macOS app unchanged, Windows portable slice real, blocked lanes documented, and CI refusing fake-green portability.
