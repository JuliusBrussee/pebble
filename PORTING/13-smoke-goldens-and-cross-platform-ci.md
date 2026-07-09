# 13 — Smoke Harness, Goldens, and Cross-Platform CI

## Scope

Files: `Sources/pebsmoke/main.swift`, `goldens/`, `Package.swift`, `.github/`, `pebble`, and smoke paths in `PebbleCore`/`pebserver`.

Goal: make smoke/goldens/CI the fail-closed regression gate for the port.

## Current blockers

- Package and targets are not Windows-ready yet.
- Smoke can construct `GameCore` and `SocialStore.shared` before any temp data root is injected.
- Golden lookup is cwd-tolerant; missing required goldens should fail closed.
- Full network/server smoke depends on Apple Network and server runtime until modules 05/12 land.
- Render smoke depends on renderer/window ABI and is optional until modules 06–09 land.

## Harness design

Add explicit config:

- `PEBBLE_CI=1`
- `PEBBLE_DATA_DIR`
- `PEBBLE_GOLDENS_DIR`
- `PEBBLE_SMOKE_SUITES`
- `PEBBLE_SMOKE_REPORT`
- `PEBBLE_REGOLD`
- CLI flags: `--data-root`, `--goldens-dir`, `--suite`, `--require-suite`, `--report-json`, `--regold`, `--render-backend`.

Suites:

- deterministic
- persistence
- protocol
- transport
- lan/direct
- server
- render (optional/backend-specific)

Required suites must run with nonzero checks; unavailable required suites fail.

## Golden policy

- Resolve goldens only from configured directory.
- Missing/malformed required golden files fail.
- Shared core goldens should be identical across macOS and Windows.
- CI forbids `PEBBLE_REGOLD` and fails if `goldens/` changes.
- Frozen goldens have no write path except deliberate local reviewed tooling.
- Use canonical JSON/line endings where practical.

## Plan

1. Add smoke config parsing and JSON report output.
2. Add data-root enforcement before any `GameCore`, `SaveDB`, settings, or social store access.
3. Make `SocialStore` injectable/resettable through module 04.
4. Split smoke into explicit suites with required-suite counts.
5. Remove cwd guessing for goldens.
6. Add path audit: every writable root must be under injected data root in CI.
7. Add protocol/framing tests including malformed/truncated/oversized behavior.
8. Add direct transport/server smoke once modules 05/12 land.
9. Add optional render smoke once modules 06–09 land; baselines are backend-specific.
10. Create GitHub Actions macOS and Windows jobs with explicit targets.

## CI gates

macOS:

- print Swift/toolchain version.
- build app/core/server/smoke.
- run required smoke with `PEBBLE_DATA_DIR=$RUNNER_TEMP/...` and `PEBBLE_GOLDENS_DIR=$GITHUB_WORKSPACE/goldens`.
- fail on golden diff.

Windows:

- install/pin official Swift 6.x toolchain.
- build explicit portable targets only.
- run required smoke with injected temp data root.
- no Bash `pebble` helper.

Render:

- optional until reliable GPU lanes exist.
- macOS Vulkan lane must record MoltenVK/portability details.
- compare only against backend-specific baselines.

## Verification gates

- Required suites run with nonzero checks on supported platforms.
- CI cannot touch real Application Support/AppData.
- `PEBBLE_REGOLD` is rejected in CI.
- Golden files are not modified by smoke.
- Smoke JSON reports suites, failures, skips with reasons, platform, Swift version, adapter/backend info.

## Done criteria

macOS and Windows CI run real portable smoke with temp roots and fail closed on missing suites/goldens, while render smoke is ready to attach backend-specific baselines when renderer dependencies land.
