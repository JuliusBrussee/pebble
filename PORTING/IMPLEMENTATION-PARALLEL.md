# Parallel Implementation Plan — Full Windows/macOS Port

Status: implementation plan after a second adversarial review workflow. This plan is for a coordinated multi-worktree push to port Pebble end-to-end, while preserving the current macOS AppKit + Metal release path.

Important: each lane includes **two adversarial review sessions inside implementation**, after real code changes. These are not planning reviews.

## Mission

Port Pebble to run on both macOS and Windows by executing six lanes in parallel:

- A — Build graph, target split, early smoke/CI, package scaffold.
- B — Core services, determinism, math/time, persistence.
- C — Network transport and dedicated server runtime.
- D — Render ABI, Metal preservation, Vulkan backend.
- E — Platform shell, audio, resource/codecs/skins.
- F — Full smoke, CI, packaging, release qualification.

The lanes run concurrently, but several gates are serial. Do not bypass a gate by stubbing or skipping checks.

## Non-negotiable constraints

1. The macOS AppKit + Metal app remains green after every slice.
2. Windows claims are target-specific: build explicit portable products only, never broad `swift build` until the support matrix says it is valid.
3. No full smoke/server/render/package job may touch real Application Support/AppData. Use injected temp roots.
4. CI must reject `PEBBLE_REGOLD` before any file write.
5. Null/headless render/audio/network/codecs are test harnesses only. They do not count as shipped parity.
6. macOS Vulkan means MoltenVK over Metal with portability enumeration/subset handling.
7. Native Vulkan/SDL/miniaudio/sockets/codecs go through a small C/C++ `CPebblePlatform` C ABI.

## Branch and worktree model

Create one integration branch plus lane worktrees:

```bash
git worktree add ../pebble-port-integration -b port/windows-macos main
git worktree add ../pebble-lane-a -b port/lane-a-manifest-ci main
git worktree add ../pebble-lane-b -b port/lane-b-core main
git worktree add ../pebble-lane-c -b port/lane-c-network-server main
git worktree add ../pebble-lane-d -b port/lane-d-renderer main
git worktree add ../pebble-lane-e -b port/lane-e-platform-audio-resources main
git worktree add ../pebble-lane-f -b port/lane-f-ci-packaging main
```

Rules:

- Each lane commits small checkpoint commits: `lane-x-NN-topic`.
- Only reviewed checkpoint commits merge into `port/windows-macos`.
- No lane merges another experimental lane directly.
- Artifacts live in ignored `artifacts/porting/...`; committed docs contain hashes/paths, not binary screenshots.
- If a checkpoint breaks macOS Metal, deterministic smoke, temp-root audit, or goldens cleanliness, revert that checkpoint.

## Gate 0 — baseline before any source mutation

Run this before editing `Package.swift` or source files.

Required artifacts:

- `swift --version`
- `swift package describe --type json`
- macOS builds for `PebbleCore`, `Pebble`, `pebserver`, `pebsmoke`
- current smoke output, with `PEBBLE_REGOLD` unset
- `git diff --exit-code -- goldens`
- macOS Metal launch/title screenshot
- fixed-seed world screenshot
- temp-root/HOME write audit
- inventory of current `PEBBLE_REGOLD`, cwd-golden, `GameCore()`, `SaveDB`, and `SocialStore.shared` paths

The fixed-seed screenshot command must actually load the world, for example using `PEBBLE_AUTOLOAD=1` with `PEBBLE_NEWWORLD`.

## Global serial gates

| Gate | Must pass before |
|---|---|
| Gate 0 baseline | any source/package/render mutation |
| Injected data root/service construction | full smoke, server, social, render, package CI |
| Deterministic-only smoke | initial CI skeleton |
| SwiftPM product/support matrix | Windows CI or Windows package claims |
| `CPebblePlatform` C ABI header/spec | Vulkan, SDL, miniaudio, sockets, codecs native work |
| Render ABI + Metal baseline | render extraction and Vulkan parity work |
| Protocol/VCK1/persistence fixtures | network/server Windows claims |
| Render/window/resources backend gates | render/package parity claims |
| Native dependency closure | Windows portable package claim |

## Lane A — Build graph, target split, CI skeleton, package scaffold

Owns: `Package.swift`, `.github/`, `pebble`, packaging scaffold, deterministic smoke target, support matrix, `CPebblePlatform` skeleton.

### Checkpoints

1. **A0 Gate 0 records** — commit only docs/hashes.
2. **A1 target graph** — explicit products; `PebbleCoreBase`; `pebsmoke-deterministic`; no `CPebblePlatform` target until files exist.
3. **A2 native ABI scaffold** — `CPebblePlatform.h`, C stub, ABI docs.
4. **A3 phase-zero data-root/service path** — remove eager storage from CI/smoke/server/package paths; legacy `GameCore()` forbidden under CI modes before disk writes.
5. **A4 deterministic smoke split** — no `GameCore`, storage, network, social, app, or resources.
6. **Review 1**.
7. **A5 CI skeleton** — macOS + Windows selected portable products only.
8. **A6 split full/render smoke lanes** — 13a/13b/13c.
9. **A7 packaging manifest/verifier** — no repo resource fallback in packaged mode.
10. **A8 Windows packaging gate docs** — no artifact success until native closures exist.
11. **Review 2**.

### Review 1 — after A1–A4 code

Entry criteria:

- Package graph builds on macOS.
- Deterministic smoke builds and runs with explicit data/goldens dirs.
- `PEBBLE_REGOLD` under CI fails before writing.
- `GameCore()` cannot be used by smoke/server/CI/package paths before injected services.
- `CPebblePlatform` header exists.

Reviewer prompt: attack target graph, temp roots, smoke split, and ABI scaffold. Find fake Windows support, eager storage, ambient paths, zero-check suites, Apple imports in portable targets, or ABI ownership/threading gaps.

Exit: zero blockers, macOS Metal still green, goldens unchanged.

### Review 2 — after A5–A8 code

Entry criteria:

- CI workflow exists.
- Package manifest/verifier exists.
- Package smoke uses temp root and packaged-mode no-repo-resource fallback.

Reviewer prompt: attack CI/package claims. Find broad Windows builds, skip-as-pass, unpinned toolchains, regold/golden mutation, package smoke using real HOME, missing license/dependency checks, null fallback counted as shipped, or broken Metal default.

Exit: zero blockers, CI/package gates fail closed.

## Lane B — Core services, determinism, math/time, persistence

Owns: `GameCore`, settings/social/storage services, math/time, executor ordering, VCK1.

### Checkpoints

1. **B0 baseline handoff** — no edits.
2. **B0.5 dependency gate** — deterministic smoke suite exists.
3. **B1 phase-zero services** — `PebbleDataPaths`, `EngineServices`, clocks, entropy, executors, stores; remove eager `SaveDB()` construction; root-aware social; app/server/smoke services.
4. **Review 1**.
5. **B2 deterministic scheduling** — ordered publication tickets, sorted public Set/Dictionary outputs, registry fingerprint, two-GameCore isolation.
6. **B3 math/time portability** — `Mat4f`/vectors, no Apple `simd` in portable code, injected clocks, UI frame time.
7. **B4 persistence/VCK1** — `WorldStore`, throwing `SQLiteWorldStore(paths:)`, centralized VCK1 codec, endian/unaligned/overflow fixtures, root-local migration.
8. **Review 2**.
9. **B5 docs/handoff**.

### Review 1 — after B1 code

Entry criteria:

- Deterministic smoke with temp data/goldens dir reports nonzero checks.
- Regold ban works.
- Dynamic write audit proves no writes outside injected root.
- Static scans show no forbidden `GameCore()`, pathless storage, `SocialStore.shared`, or `vcSupportDir()` in CI/smoke/server/core paths.

Reviewer prompt: prove the branch can still touch real user data or construct storage/social before injected roots.

Exit: zero blockers; no B2/B3/B4 starts until closed.

### Review 2 — after B2–B4 code

Entry criteria:

- Deterministic, persistence, and protocol/VCK1 suites pass.
- SQLite ownership/pin decision recorded.
- Metal app build/screenshot still green.

Reviewer prompt: attack deterministic ordering, math drift, platform imports, VCK1 duplication, SQLite safety, migration safety, and Metal regression.

Exit: zero blockers, goldens unchanged, temp-root audit clean.

## Lane C — Network transport and dedicated server

Owns: `NetProtocol`, sessions/transports, social injection in network paths, direct TCP, server CLI/runtime.

### Checkpoints

1. **C0 baseline/audits**.
2. **C1 protocol/framing fixtures** — exact decode policy; no protocol bump without approval.
3. **C2 stable wire order** — sorted protocol-visible outputs.
4. **C3 transport interfaces + in-memory transport**.
5. **C4 Apple Network adapter isolation**.
6. **C5 services/social/server preparse** — `pebserver --help --data-dir` creates zero files.
7. **Review 1**.
8. **C6 CPebblePlatform sockets** — only after common ABI exists.
9. **C7 direct TCP adapter + endpoint parser** — IPv4, hostnames, bracketed IPv6.
10. **C8 session refactor** — callbacks on game executor.
11. **C9 UI endpoint neutrality** — no `NWEndpoint` in screens.
12. **C10–C12 server controller/runtime/smoke**.
13. **C13 selected-target CI**.
14. **Review 2**.

### Review 1 — after C1–C5 code

Entry criteria:

- Protocol/in-memory transport suites pass with nonzero checks.
- Server help creates zero files.
- Portable/core/server code has no Apple Network types outside adapter.
- No network/smoke/server `SocialStore.shared` or default `GameCore()`.

Reviewer prompt: attack fake Windows networking, real data writes, corrupt-frame behavior, unstable wire order, Apple Network leaks, and server preparse.

Exit: zero blockers.

### Review 2 — after C6–C13 code

Entry criteria:

- Direct native socket loopback passes.
- Server process smoke uses temp root.
- `READY` reports actual bound port.
- Windows selected-target CI passes or fails hard.

Reviewer prompt: attack socket ABI, direct TCP, endpoint parsing, server lifecycle, shutdown, temp-root bypass, and skip-as-pass CI.

Exit: zero blockers and direct-IP/server capability can be handed to packaging.

## Lane D — Render ABI, Metal preservation, Vulkan backend

Owns: render ABI, backend facade, Metal backend, Vulkan backend, shader/capture contracts.

### Checkpoints

1. **D00 baseline render records** — no source edits.
2. **D01 render/platform/shader/capture docs**.
3. **D02 renderer target skeletons** — selected products only.
4. **D03 render ABI byte layouts/tests**.
5. **D04 `CPebblePlatform` ABI layout tests**.
6. **D05 `FrameBuilder`/`RendererBackend`** — no `GameCore`, `MTL*`, `NS*`, `Vk*`, or SDL types in public API.
7. **D06 Metal consumes neutral packets** — do not whole-file move before dependencies inverted.
8. **D07a–c UI, particles, entities/gear extraction**.
9. **D08 deterministic packet smoke + safe Metal smoke**.
10. **Review 1**.
11. **D09 shader manifest/reflection**.
12. **D10 Vulkan bootstrap**.
13. **D11 title/UI**.
14. **D12 chunks/shadows**.
15. **D13 entities/gear/particles/sprites/viewmodel**.
16. **D14 postprocess/readback**.
17. **D15 render CI**.
18. **Review 2**.

Resource/capture payload extraction waits for Lane E resource/codecs.

### Review 1 — after D01–D08 code

Entry criteria:

- Render ABI and facade exist.
- Metal consumes neutral packets.
- UI/particle/entity extraction slices landed.
- Deterministic packet smoke passes.
- Metal baseline still green.

Reviewer prompt: attack render ABI incompleteness, platform type leaks, Metal not using Vulkan-bound packets, unstable draw order, missing C ABI rules, shader binding drift, temp-root/golden safety, and screenshot regression.

Exit: zero blockers before Vulkan implementation proceeds.

### Review 2 — after Vulkan + render CI code

Entry criteria:

- Vulkan bootstrap/title/world/entity/particle/postprocess/readback slices implemented.
- MoltenVK portability logs attached.
- Validation/sync clean.
- Metal remains default/green.

Reviewer prompt: attack Vulkan parity, MoltenVK handling, validation errors, shader reflection drift, capture color/row/alpha mismatch, Windows skip-as-pass, dependency/license closure, and Metal regression.

Exit: zero blockers and capabilities marked safe for packaging.

## Lane E — Platform shell, audio, resources/codecs/skins

Owns: platform services, AppKit runtime extraction, SDL/null shell, miniaudio sink, PNG/ZIP codecs, resource catalog, skins, capture codec.

### Checkpoints

1. **E0 baseline guards**.
2. **E1 target/service/C ABI scaffold** — serial; no parallel header edits.
3. **E2 portable audio core** — no app wiring yet.
4. **E3a portable codecs**.
5. **E3b resource locator/catalog** — waits for data-root gate.
6. **Review 1**.
7. **E5 AppKit shell extraction** — waits for clock/data-root/render facade/network constraints.
8. **E6 resource renderer integration** — waits for render facade/codecs.
9. **E7 SDL null shell**.
10. **E8 miniaudio sink**.
11. **E9 macOS default integrated slice**.
12. **E10 Windows selected portable smoke**.
13. **E11 docs/license updates**.
14. **Review 2**.

### Review 1 — after E1–E3b code

Entry criteria:

- Portable audio offline smoke built and run.
- Codec/catalog smoke built and run.
- `CPebblePlatform` ABI scaffold and product membership exist.
- No app/runtime rewiring yet.

Reviewer prompt: attack fake Windows support, Apple imports, temp-root violations, unsafe C ABI, audio callback design, codec security/color bugs, missing licenses, and dead/unbuilt targets.

Exit: zero blockers.

### Review 2 — after E5–E11 code

Entry criteria:

- AppKit extraction, resources, miniaudio, SDL null shell, Windows selected CI, docs/license updates exist.
- Metal app screenshots still match.
- Portable targets scan clean.

Reviewer prompt: attack macOS behavior regressions, service leaks, hidden real-user writes, platform coupling in portable code, key/focus/fullscreen regressions, capture/color contract, null fallback overclaims, missing notices, and skip-as-pass.

Exit: zero blockers.

## Lane F — Full smoke, CI, package, release qualification

Owns: final CI orchestration, full smoke gating, package manifests/verifiers, macOS and Windows artifacts.

Lane F has two phases:

- **F1 skeleton** — deterministic smoke/CI and package verifier skeleton.
- **F2 integration** — full smoke, server/render CI, macOS/Windows packages after tagged prerequisites.

### Checkpoints

1. **F0 Gate 0 and artifact ignore**.
2. **F1 deterministic smoke harness** — quarantines unsafe legacy sections.
3. **F2 in-binary CI safety** — regold ban, required suite nonzero checks.
4. **F3 deterministic CI matrix** — macOS + Windows selected products.
5. **F4 package manifest/verifier skeleton**.
6. **Review 1**.
7. **F2 integration branch starts** — merge tagged lane outputs only.
8. **F5 native ABI/package gate**.
9. **F6 full smoke** — after 01/02/04/05/12.
10. **F7 server CI** — after socket/server gates.
11. **F8 render CI** — after render/window gates.
12. **F9 macOS package** — after data-root/resource gates.
13. **F10 Windows package** — after all native/dependency gates.
14. **Review 2**.
15. **Final docs/release workflow**.

### Review 1 — after F1 skeleton

Entry criteria:

- Gate 0 docs exist.
- Deterministic smoke and CI safety exist.
- Windows deterministic selected-target CI exists.
- Package verifier skeleton exists.
- No full/server/render/package CI enabled.

Reviewer prompt: prove fake Windows support, real user writes, CI regold, skip-as-pass, cwd goldens, deterministic smoke using GameCore/storage/social/network/resources, missing Gate 0 artifacts, or support overclaim.

Exit: zero blockers.

### Review 2 — after full CI/packages

Entry criteria:

- Tagged prerequisites are merged.
- Full smoke, render smoke, native gates, macOS package, Windows package all exist.
- Package smokes use temp roots.

Reviewer prompt: attack release readiness: data writes, legacy `GameCore()`, null fallback parity, skipped GPU/native lanes, missing ABI rules, DLL/runtime/license closure, MoltenVK overclaim, broken Metal default, source-checkout dependencies, README overclaims.

Exit: zero blockers, artifacts checksummed, support matrix truthful.

## Integration cadence

Daily during port:

1. Each lane posts checkpoint commit SHA and verification report.
2. Integration branch merges only checkpoint commits with passing lane-local gates.
3. Run shared checks:
   - macOS build for app/core/server/smoke
   - deterministic smoke with temp root
   - package graph/support matrix diff
   - portable import scans
   - `git diff --exit-code -- goldens`
4. If broken, revert last lane checkpoint from integration, not unrelated lane work.

After each lane Review 1:

- Merge Review-1-passed checkpoint into integration if global gates pass.
- Enable dependent lanes' next phase only where serial gates allow.

After each lane Review 2:

- Merge only with review report committed.
- Mark capabilities as real, experimental, or blocked in `docs/windows-support-matrix.md`.

## Global CI commands

Representative commands; exact target names may change with Lane A.

```bash
# macOS baseline/build
swift package describe --type json
swift build -c release --target PebbleCore
swift build -c release --target Pebble
swift build -c release --target pebserver
swift build -c release --target pebsmoke

tmp=$(mktemp -d)
PEBBLE_CI=1 \
PEBBLE_DATA_DIR="$tmp/data" \
PEBBLE_GOLDENS_DIR="$PWD/goldens" \
swift run -c release pebsmoke -- \
  --data-root "$tmp/data" \
  --goldens-dir "$PWD/goldens" \
  --require-suite deterministic \
  --report-json "$tmp/report.json"

git diff --exit-code -- goldens/
```

Windows CI uses explicit selected targets only and prints Swift/MSVC/SDK/ICU/arch/runtime details.

## Rollback and kill switches

Immediate rollback of the latest checkpoint if any occurs:

- macOS `Pebble` build fails.
- Metal title/fixed-seed screenshot regresses without approved baseline update.
- Smoke writes outside injected root.
- CI accepts `PEBBLE_REGOLD`.
- Any required suite has zero checks or skips as pass.
- `goldens/` changes without approved regold workflow.
- Portable target imports Apple frameworks/native types outside adapters.
- Windows job uses broad unsupported `swift build`.
- Native ABI changes without version/size/layout tests.
- Null/headless backend counted as shipped capability.

Kill switch:

- If two consecutive fix loops cannot close a Review P0 blocker, freeze that lane and cut scope at the last reviewed checkpoint. Update support matrix to mark downstream claims blocked.

## Final done criteria

The port is done when:

- macOS Metal app remains default and green.
- Windows portable client launches through SDL + Vulkan.
- macOS optional Vulkan path works through MoltenVK with portability handling.
- PebbleCore deterministic smoke/goldens pass on macOS and Windows.
- Full smoke uses temp roots and passes required suites with nonzero checks.
- Direct-IP multiplayer and `pebserver` work cross-platform.
- Resource packs, skins, captures, audio, UI, and packaging work without Apple-only dependencies in portable targets.
- Mac and Windows packages include assets, licenses, native dependencies/runtime closure, and pass package smoke with no source-checkout dependency.
- `docs/windows-support-matrix.md` and README truthfully describe supported, experimental, and blocked capabilities.
