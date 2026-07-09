# Implementation Plan v2 — Orchestration

Supersedes the execution model in `IMPLEMENTATION-PARALLEL.md`. The lane *contents* there are still
correct; what follows replaces how they are scheduled, staffed, and verified.

Written after one real multi-agent run against this repo. Every number below is measured, not estimated.

## Why v2

The v1 run launched a scaffold agent and seven parallel worktree agents in a single workflow. Outcome:

| | |
|---|---|
| Scaffold | landed, 16 min (`1b32632`) |
| Lanes that produced a commit | 3 of 7 — network, render-abi, codecs |
| Lanes that produced nothing | 4 of 7 — math-time, persistence, audio-core, sockets |
| Lane wall time (the three that ran) | 25 / 34 / 47 min |

Four lanes died on a precondition check. Git worktrees fork from HEAD **as of workflow launch**, not as
of agent spawn — so they were based on `1c0ea58`, the scaffold's *parent*. The scaffold's new targets
did not exist in their trees, so their verify commands could not have run. The four agents detected this
and stopped, correctly. Two of the three that *did* commit (network, render-abi) were on the same stale
base and worked anyway, ignoring the gate, which means their self-reported verification is worthless.

The stale base is a one-line bug. It concealed three design errors that cost far more.

**1. Breaking API changes were made inside parallel lanes.** `EngineServices` became throwing;
`Mat4` changed from `simd_float4x4` to a hand-rolled struct. Both are cross-cutting signature changes,
made concurrently, by agents that could not see each other. All reconciliation cost then landed on one
serial integrator holding seven diffs at once. That is the worst place in the system to pay it.

**2. Every lane ran `swift build -c release --target Pebble`.** A cold release build of an 11.5k-LOC
AppKit+Metal app plus 35k LOC of core, in a cold worktree, seven times. Three lanes could plausibly
break the app. The other four could not. That check belongs at the integrator, once.

**3. Waves have barriers.** Nothing in wave N+1 can start until the slowest lane of wave N finishes,
even when it has no dependency on that lane. Most of the port is not on the critical path at all.

## Principles

### P1 — Serial for interfaces, parallel for implementations

Every type and signature a wave needs is declared in a single **API commit**, authored by one agent in
the main working tree, before any fan-out. It is additive: it compiles, it changes no behaviour, old
names survive as typealiases. Lanes then only add files and fill in bodies.

Consequence: lane diffs touch disjoint files by construction, merges are trivial, and the integrator
degrades from *redesigner* to *build-and-run*.

For wave 1b the API commit declares `WorldStore`, `MonotonicClock`, `Mat4f` (+ `typealias Mat4`), the
`NetTransportConnection`/`Listener`/`Factory` trio, and the `PBSocket` C declarations.

### P2 — Tests are the spec, and a different agent writes them

The API commit also ships each lane's `Suite_*.swift` with real test bodies, **failing**. A lane's
success criterion collapses to one command: `swift run pebsmoke-portable --require-suite <name>` exits 0.

This is what makes cheaper models viable — the ambiguity was spent upstream, once, by a stronger model.
It also removes self-grading. In the v1 run, network and render-abi both reported passing verifications
they could not have executed. An agent must never be the sole author of the test that clears it.

### P3 — The critical path is the schedule

The long pole is exactly six sequential steps:

```
RenderABI ─→ FrameBuilder ─→ Metal-consumes-packets ─→ Vulkan bootstrap ─→ Vulkan passes ─→ render CI
```

Nothing else is on it. Persistence, networking, sockets, codecs, audio, resources, server runtime,
packaging — all off-path. They must run *in the render chain's shadow*, not in a wave that gates it.

In `Workflow` terms: `pipeline()` over the render chain, with the off-path lanes as concurrent
`agent()` calls in the same phase. Reach for `parallel()` only where a stage genuinely needs every
prior result at once (dedup before verification; the integrator's merge list).

### P4 — Only the integrator builds the world

| Who | Builds |
|---|---|
| Leaf lane | `swift build --target <its own target>` (debug) + its own suite |
| Render-chain lane | debug build of `Pebble` + goldens diff |
| Integrator | `-c release` across the full graph, full smoke, temp-root audit, hygiene scans |

A lane that cannot break the app does not get to spend four minutes proving it didn't.

### P5 — Verified or blocked. There is no third state

Null and headless backends are test harnesses. A capability is `shipped` only when a CI job **compiles
and runs** it on that OS. Nothing has ever executed on Windows hardware, so Windows caps at
`experimental` for the duration of this plan, and no Windows packaging work begins before a Windows
CI job is green.

## Agent staffing

| Work | Model | Effort | Rationale |
|---|---|---|---|
| API commit, integration, render extraction | Opus | medium | judgment-dense, cross-file, little output, high blast radius |
| Leaf implementation against a test list | Sonnet | medium | the spec did the reasoning; Sonnet-at-high paid for it twice |
| Review lenses (6–8, each narrow) | Opus | low | finding defects rewards breadth over depth |
| Refutation of each finding | Sonnet | low | cheap filter before a fix agent is spent |

Never route workflow agents to Fable; it orchestrates the main loop only.

The seams get Opus not because they are large but because they are where being wrong costs an hour.
A DEFLATE decoder with thirty named test cases does not need reasoning effort — it needs the test cases.

## Mechanics

### Worktree base

Worktrees fork from HEAD at workflow launch. Two fixes, use both:

1. Land the API commit from the **main loop or a prior workflow invocation**, not from the same
   workflow that fans out. Read its result, then launch the fan-out.
2. Defensively, each lane's first action is `git merge --ff-only <API_SHA> || git merge <API_SHA>`.
   Worktrees share the object database, so the commit is always reachable. Never a hard stop — a lane
   that halts on a stale base wastes its whole slot, as four did.

### Build cache — measured, and rejected

Worktrees start cold. The obvious optimisation is to APFS-clone the main tree's `.build` into each
worktree with `cp -c -R`. **Do not.** Measured on this repo:

| | wall clock |
|---|---|
| cold worktree, full debug build | 68.5 s |
| worktree seeded with a cloned `.build` | 75.3 s |

The clone copies 848 MB, and SwiftPM then recompiles 155 of 156 tasks anyway — Swift module records and
the C target's PCH pin absolute paths (`error: PCH was compiled with module cache path '…/pebble/.build/…'
but the path is currently '…/worktree/.build/…'`). Clearing `ModuleCache` fixes the hard error but not
the invalidation. The clone is strictly slower than starting cold.

A full cold debug build of the whole graph is only ~70 s, so this does not matter. Under P4 a leaf lane
builds one target, which is faster still. The saving was never in the cache; it was in not building
things you cannot break.

### Merge

Each lane commits exactly one squashed commit and returns its SHA. The integrator merges by SHA
(`git merge --no-ff <sha>`), in dependency order. Disjoint ownership under P1 means conflicts are a
bug in the ownership map, not a normal event — if one occurs, fix the map.

## Verification contracts

### Fail-closed suites

`pebsmoke-portable --require-suite X` exits non-zero when X is unknown **or ran zero checks**. A
placeholder suite therefore fails until a lane fills it. This is the mechanism that makes P2 work; do
not weaken it.

Prove it in CI: `--require-suite doesnotexist` must exit non-zero.

### Validation liveness — the trap

Homebrew's `VkLayer_khronos_validation.json` ships a bare `library_path`. `dlopen` cannot resolve it,
so the loader **skips the layer and still returns `VK_SUCCESS`**. `vulkaninfo` reports
`Instance Layers: count = 1` the whole time. A "validation clean" run against an unloaded layer is a
skip-as-pass, and Lane D's Review-2 exit criterion is exactly that phrase.

Fixed locally by writing a corrected manifest with an absolute `library_path` to
`/opt/homebrew/etc/vulkan/explicit_layer.d/`. The ICD needs no env var; the loader finds
`/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json` itself.

**Any harness asserting validation cleanliness must first assert validation is loaded**, by triggering
a deliberate VUID and requiring it to fire. Positive control: leak a `VkDebugUtilsMessengerEXT` across
`vkDestroyInstance` and expect

```
vkDestroyInstance(): VkInstance 0x… has 1 leaked objects that have not been destroyed.
```

### Vulkan gets a real feedback loop

This is the largest quality change in v2, and it is only possible because MoltenVK now runs here.

Build a headless `pebvk` that renders offscreen and dumps PNG. Every Vulkan slice's success criterion
becomes: *render this scene through MoltenVK, dump it, compare against the Metal capture within
tolerance, with validation loaded and clean.* Not "the code looks right."

Shaders: hand-write GLSL per pipeline from `ShaderManifest`, compile with `glslc`, check with
`spirv-val`, and assert via reflection that the binding table matches the manifest. Parallelizes per
pipeline and needs no GPU.

### macOS regression guard

`Metal-consumes-neutral-packets` is the single most dangerous agent in the port: it can silently
regress the shipped product. It gets goldens plus a fixed-seed screenshot diff before and after, and
it shares a commit with nothing else.

## Toolchain (verified 2026-07-09, macOS arm64)

| | version | proof |
|---|---|---|
| vulkan-loader / headers | 1.4.350.1 | `vkCreateInstance` → `VK_SUCCESS` |
| MoltenVK | 1.4.1 | enumerates `Apple M3 Pro`, api `1.2.334` |
| validation layers | 1.4.350.1 | emits a real object-leak VUID |
| glslc / glslangValidator | 2026.2 / 16.3.0 | GLSL → SPIR-V |
| spirv-val / spirv-cross | 1.4.350.1 | validated, cross-compiled to MSL |
| cmake / ninja / pkgconf | 4.3.4 / 1.13.2 / 2.5.1 | on PATH |
| SDL3 | 3.4.10 | `pkg-config sdl3` |

Two constraints fall out of this:

- MoltenVK reports Vulkan **1.2**, not 1.4, and requires `VK_KHR_portability_subset` on the device.
  Instances need `VK_KHR_portability_enumeration` +
  `VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR`. Do not request 1.3+ device features.
- **`-lSDL2` does not link SDL2.** `sdl2-compat` owns `libSDL2.dylib` and `sdl2.pc` even though the
  real `sdl2` formula is installed, so `pkg-config sdl2` links an SDL2-on-SDL3 shim. Target **SDL3**
  directly: it is what is underneath either way, it has first-class `SDL_Vulkan_CreateSurface`, and it
  ships official Windows VC dev packages.

`miniaudio` is not in Homebrew — single public-domain/MIT-0 header, v0.11.25. Vendor into
`Sources/CPebblePlatform/vendor/`.

## Stages

Landed already: `1b32632` scaffold · `d02a1ef` network · `441eccf` render-abi · `d5a2b18` codecs, plus
their merges. Network and render-abi are **unverified** (P2 violation) and are re-checked at stage 0.

### Stage 0 — recover (Opus/medium, serial, main tree)

Re-run the full gate against merged `main`. Confirm `PebbleCore` no longer imports `Network`,
`SQLite3`, or `simd`. Confirm the network and render-abi suites actually execute and report non-zero
checks. Whatever they claimed, believe only what runs now.

### Stage 1 — API commit (Opus/medium, serial, main tree)

Declare `WorldStore`, `MonotonicClock`, `Mat4f` + `typealias Mat4`, `PBSocket` C decls. Write the four
lost lanes' suites with real, failing test bodies: `Suite_Math`, `Suite_Persistence`, `Suite_Audio`,
`Suite_Sockets`. Additive only — `swift build -c release --target Pebble` stays green, goldens unchanged.

### Stage 2 — fan-out (Sonnet/medium, worktrees, concurrent)

Four leaf lanes implement against their failing suites: math-time, persistence, audio-core, sockets.
Each merges the API commit first, builds only its own target in debug, and exits when its suite is green.

Concurrently, off the critical path and not gating it: resources (`ResourcePacks`/`Skins` onto
`PebbleCodecs`), audio sink (miniaudio via C ABI), server runtime.

### Stage 3 — render chain (pipelined, starts immediately, does not wait on stage 2)

| Slice | Model | Gate |
|---|---|---|
| `FrameBuilder` emits neutral packets | Opus/medium | deterministic packet smoke, stable draw order |
| Metal consumes neutral packets | Opus/medium | goldens + fixed-seed screenshot diff, own commit |
| Vulkan bootstrap (`pebvk` headless) | Sonnet/medium | instance+device on MoltenVK, validation loaded & clean |
| Vulkan passes ×N (title, chunks, shadows, entities, particles, post) | Sonnet/medium | offscreen PNG vs Metal capture, per pass |
| Render CI | Sonnet/medium | job runs `pebvk`, fails on any VUID |

### Stage 4 — integrate (Opus/medium, serial)

Merge by SHA. Full-graph `-c release`. Full smoke under an injected temp root with `HOME` redirected to
an empty dir and `find` proving nothing was written. Hygiene scans. `git diff --exit-code -- goldens/`.
Update `docs/windows-support-matrix.md` to what CI actually proves.

### Stage 5 — review (two gates total, not twelve)

Six to eight narrow Opus/low lenses in parallel: overclaim, data safety, memory safety on untrusted
input, macOS regression, C ABI/threading, determinism. Every finding goes to an independent Sonnet/low
refuter prompted to *refute*, defaulting to refuted when uncertain. Only survivors reach a fix agent,
which must write a check that fails before its fix and passes after.

Gate 1 after stage 2 + the Metal-consume slice. Gate 2 before any release claim.

## Schedule

| | v1 measured / projected | v2 projected |
|---|---|---|
| Wave 1 remainder | 1.5–2 h | 45 min |
| Render chain | — | 5.5 h (the whole schedule) |
| Everything else | 6–12 h | hidden inside the chain |
| **Total from now** | **12–18 h** | **≈ 7 h** |

Risks, named rather than discovered: the `.build` clone may not survive the path change (costs back
~30 min); Opus-at-medium on the seam is a bet, and a fumble is one 20-minute retry; the Metal-consume
slice can regress the shipped app, which is why it is isolated and screenshot-gated.

## Rollback

Immediate revert of the newest checkpoint on any of:

- `swift build -c release --target Pebble` fails
- Metal title or fixed-seed screenshot regresses without an approved baseline update
- smoke writes outside the injected root
- CI accepts `PEBBLE_REGOLD`
- a required suite reports zero checks, or skips as pass
- `goldens/` changes outside an approved regold workflow
- a portable target imports an Apple framework outside its adapter
- a Windows job runs a broad `swift build`
- native ABI changes without version/size/layout tests
- a null or headless backend is counted as shipped capability
- **a Vulkan job reports "validation clean" without first proving the layer is loaded**

Kill switch: if two consecutive fix loops cannot close a P0, freeze that lane at its last reviewed
checkpoint and mark every downstream claim `blocked` in the support matrix.

## Done

- macOS Metal app remains the default and stays green.
- `PebbleCore` is free of `Network`, `SQLite3`, and `simd`.
- Windows CI compiles and runs `pebsmoke-portable` with every suite required.
- Vulkan renders Pebble offscreen through MoltenVK, matching the Metal capture, validation loaded and clean.
- Direct-IP multiplayer and `pebserver` work through the portable transport.
- `docs/windows-support-matrix.md` and the README say `experimental` where nothing has run on Windows
  hardware, and `blocked` where nothing has run at all.
