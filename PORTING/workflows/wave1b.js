export const meta = {
  name: 'pebble-port-wave1b',
  description: 'v2 orchestration: recover, serial API commit, leaf lanes fan out while the render chain pipelines, integrate, one review gate',
  phases: [
    { title: 'Recover', detail: 'believe only what runs now — re-verify the unverified lanes', model: 'opus' },
    { title: 'API', detail: 'serial additive interface commit + failing suites', model: 'opus' },
    { title: 'Build', detail: 'leaf lanes (sonnet) concurrent with the render chain (pipelined)' },
    { title: 'Integrate', detail: 'merge by sha, full release build, temp-root audit', model: 'opus' },
    { title: 'Review', detail: 'narrow lenses -> refute -> fix' },
  ],
}

const REPO = '/Users/julb/Desktop/GitHub/pebble'

// ---------------------------------------------------------------- shared prose

const RULES = `
Pebble: 50k-LOC Swift block-survival game (macOS AppKit + Metal), being ported to Windows. Repo: ${REPO}

HARD RULES
1. \`swift build -c release --target Pebble\` must stay green. The macOS Metal app is the shipped product.
2. \`git diff --exit-code -- goldens/\` stays clean. Never set PEBBLE_REGOLD. Never edit goldens/.
3. Nothing writes outside an injected data root. No new use of ~/Library/Application Support.
4. Portable targets must not import AppKit, Metal, MetalKit, QuartzCore, AVFoundation, Network,
   SQLite3, Darwin, simd, CoreGraphics, ImageIO, or Compression. Foundation is fine.
5. Null/headless backends are test harnesses. Never claim them as platform support.
6. Never skip a test to make it pass. A required suite with zero checks is a failure.
7. Never \`git push\`.

TOOLCHAIN (verified on this machine)
  MoltenVK 1.4.1 reports Vulkan 1.2 and requires VK_KHR_portability_subset on the device.
  Instances need VK_KHR_portability_enumeration + VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR.
  glslc, glslangValidator, spirv-val, spirv-cross, cmake, ninja, pkg-config all on PATH.
  Validation layers load with no env vars, but a "clean" run proves nothing unless you first prove the
  layer is LOADED by triggering a deliberate VUID.
  \`-lSDL2\` links the sdl2-compat shim, not SDL2. Use SDL3 (\`pkg-config sdl3\`).
`

const SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['sha', 'summary', 'filesChanged', 'verification', 'blocked'],
  properties: {
    sha: { type: 'string', description: 'HEAD after your single squashed commit, or "" if nothing committed' },
    summary: { type: 'string' },
    filesChanged: { type: 'array', items: { type: 'string' } },
    verification: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false, required: ['command', 'passed'],
        properties: { command: { type: 'string' }, passed: { type: 'boolean' }, output: { type: 'string' } },
      },
    },
    blocked: { type: 'array', items: { type: 'string' } },
  },
}

// P1 defence: worktrees fork from HEAD at workflow launch, so a lane may be based on a stale commit.
// Never hard-stop on it (v1 lost 4 of 7 lanes that way) — merge forward and carry on.
const rebase = (sha) => `
YOU ARE IN AN ISOLATED GIT WORKTREE, possibly forked from a commit older than the API commit.
FIRST, unconditionally:
    git merge --ff-only ${sha} 2>/dev/null || git merge --no-edit ${sha}
    git log --oneline -1 && git merge-base --is-ancestor ${sha} HEAD && echo BASE_OK
If BASE_OK does not print, say so in \`blocked\` and stop. Otherwise continue — do NOT stop merely
because \`git log -1\` does not name the API commit.

Then, to start warm instead of cold:
    cp -c -R ${REPO}/.build .build 2>/dev/null || true    # APFS reflink; harmless if SwiftPM rejects it

Commit exactly ONE squashed commit (\`git add -A && git commit -m "<lane>: <summary>"\`) and return its sha.
A smaller correct commit beats a larger broken one. Never commit code that does not build.
`

// ---------------------------------------------------------------- Stage 0: recover

phase('Recover')

const recover = await agent(`${RULES}

TASK: Stage 0 — recover. Work directly in ${REPO} on \`main\`. Do not fan out, do not add features.

A previous run merged three lanes. Two of them (network \`d02a1ef\`, render-abi \`441eccf\`) were built on a
stale base that did not contain the \`pebsmoke-portable\` target, so their self-reported verification could
not have executed. Believe only what runs now.

1. \`git status --porcelain\` must be clean. If it is not, the previous integrator died mid-merge — inspect
   \`git log --oneline -8\`, finish or abort the merge, and say what you found in \`blocked\`.
2. Establish ground truth. Run and record REAL output for each:
     swift build -c release --target Pebble
     swift build -c release --target pebserver
     swift build -c release --target pebsmoke
     swift build -c release --target pebsmoke_portable
     swift run -c release pebsmoke-deterministic --require-suite deterministic
     swift run -c release pebsmoke-portable --require-suite vck1 --require-suite protocol --require-suite renderabi --require-suite codecs
     swift run -c release pebsmoke-portable --require-suite doesnotexist   # MUST exit nonzero (fail-closed proof)
     tmp=$(mktemp -d); PEBBLE_CI=1 PEBBLE_DATA_DIR="$tmp/data" swift run -c release pebsmoke -- --data-root "$tmp/data" --goldens-dir "$PWD/goldens"
     git diff --exit-code -- goldens/
     git grep -nE 'import (Network|SQLite3|simd)' -- Sources/PebbleCore
3. For each of protocol/renderabi/codecs, report the ACTUAL check count the harness printed. A suite that
   runs zero checks is a failure even if the lane claimed otherwise.
4. Fix only what is broken. Do not redesign. If \`PebbleCore\` still imports Network/SQLite3/simd, move the
   residue into PebbleNetApple / PebbleStoreSQLite / MathX and note it.
5. Commit as \`port: stage 0 — recover and verify wave 1 merges\`, or return sha "" if nothing needed fixing.

In \`blocked\`, list every claim from the previous run you could NOT reproduce.
`, { label: 'recover', phase: 'Recover', model: 'opus', effort: 'medium', schema: SCHEMA })

if (!recover) { log('stage 0 failed hard'); return { aborted: 'recover' } }
log(`stage 0: ${recover.blocked.length} unreproducible claims from wave 1`)
if (recover.blocked.length) log(recover.blocked.map((b) => '  - ' + b).join('\n'))

// ---------------------------------------------------------------- Stage 1: API commit (P1 + P2)

phase('API')

const api = await agent(`${RULES}

TASK: Stage 1 — the API commit. Work directly in ${REPO} on \`main\`. You are the ONLY agent that will
touch Package.swift this wave. Everything you write is ADDITIVE: it compiles, it changes no behaviour,
every existing name survives (typealias where a type moved).

This exists because v1 let four parallel lanes each make a breaking signature change, and dumped the
reconciliation on one integrator. Interfaces are serial. Implementations are parallel.

PART A — declare the interfaces (no implementations beyond what compiles):

1. \`Sources/PebbleCore/Game/WorldStore.swift\`
   \`public protocol WorldStore: AnyObject\` — every method GameCore/pebsmoke/pebserver actually call on
   \`SaveDB\` today (grep \`db\\.\` across Sources). Plus \`public final class InMemoryWorldStore: WorldStore\`,
   fully implemented, portable, no SQLite. Leave \`SaveDB\` working exactly as it is; do not delete it.
   \`EngineServices\` gains \`makeStore: (PebbleDataPaths) throws -> any WorldStore\` with a default that
   preserves today's behaviour. PebbleCore must NOT depend on PebbleStoreSQLite — that is a cycle.

2. \`Sources/PebbleCore/Core/Clock.swift\`
   \`public protocol MonotonicClock: Sendable { func nowSeconds() -> Double }\`, \`SystemMonotonicClock\`
   built on \`ContinuousClock\` (stdlib, portable — NOT Darwin, NOT QuartzCore), and a settable \`FixedClock\`.

3. \`Sources/PebbleCore/Core/Mat4f.swift\`
   \`public struct Mat4f\`: 4 × \`SIMD4<Float>\` columns, column-major, EXACTLY 64 bytes, Equatable, Sendable.
   \`init(columns:)\`, \`subscript(column:)\`, \`*\` (mat×mat, mat×vec), \`transpose\`, \`inverse\`, \`.identity\`.
   Do NOT yet rewrite MathX.swift. Just land the type. The memory layout must be byte-identical to
   \`simd_float4x4\` so \`Sources/Pebble\` can keep feeding it to \`setVertexBytes\`.

4. \`Sources/CPebblePlatform/include/CPebblePlatform.h\`
   Declare the socket ABI ONLY (no .c implementation): opaque \`PBSocket\`, \`pb_socket_listen/accept/
   connect/send/recv/shutdown/close/set_nodelay\`. Add PB_PLATFORM_TIMEOUT / CLOSED / WOULD_BLOCK
   WITHOUT renumbering existing enum values. Bump PB_PLATFORM_ABI_VERSION to 2. Every crossing struct
   starts with \`uint32_t struct_size\`. Document ownership and the threading contract in
   PORTING/CPebblePlatform-ABI.md, including that \`pb_platform_last_error\` must become thread-local.
   Stub the new functions in CPebblePlatform.c returning PB_PLATFORM_UNAVAILABLE so it links.

PART B — write the failing suites. THIS IS THE SPEC. You are not the agent who will make them pass.

Fill these four files with real, thorough, currently-FAILING test bodies:

  Suite_Math.swift        (MathSuite, "math", >=20 checks)
     Mat4f is 64 bytes, column-major byte order, identity, associativity, lookDir orthonormality,
     inverse*matrix ~= identity within 1e-5, cross/dot/normalize vs hand-computed values, normalize of
     the zero vector (pin the behaviour), FixedClock determinism.

  Suite_Persistence.swift (PersistenceSuite, "persistence", >=15 checks)
     InMemoryWorldStore ONLY — no SQLite, it must run on Windows. Chunk record round-trip, dim state,
     player snapshot, advancement sets, overwrite semantics, missing-key reads, and a VCK1 byte-compat
     check that a record in the old on-disk layout still decodes.

  Suite_Audio.swift       (AudioSuite, "audio", >=20 checks)
     Hardcoded WAV byte fixtures, no device, no data root. s16/u8/f32 × mono/stereo decode; reject bad
     RIFF magic, missing fmt/data chunk, unsupported codec tag, truncated data, declared size past the
     buffer. Resampler: 2x up and 2x down frame counts, no phase drift over 100k frames. Mixer: silence
     is exact zeros; one voice at gain 1 reproduces the source bit-exactly; two identical voices sum;
     distance attenuation monotonic; pan-law endpoints; soft clip |x| <= 1.0; voice-pool exhaustion
     steals the oldest; render twice from the same state is identical.

  Suite_Sockets.swift     (SocketsSuite, "sockets", >=15 checks)
     127.0.0.1 with port 0 (ephemeral) ONLY — never a hardcoded port, never bind 0.0.0.0. Every test
     bounded under 5 seconds. listen reports a real nonzero bound port; connect+accept; send/recv round
     trip; 1 MiB in chunks arrives intact and ordered; recv timeout returns PB_PLATFORM_TIMEOUT without
     consuming data; peer close -> recv returns 0/OK (EOF); send after peer close errors without SIGPIPE;
     double close is safe; connect to a closed port fails cleanly; accept timeout; nodelay; capabilities
     reports abi_version 2 and has_sockets 1; struct_size layout asserts.

Write the suites against the interfaces from Part A as if the implementations existed. They will fail
today (InMemoryWorldStore aside). That is the point — \`--require-suite\` is fail-closed, so a suite with
zero checks or a failing check is a red gate the implementing lane must turn green.

VERIFY (paste real output):
  swift build -c release --target Pebble          # still green
  swift build -c release --target pebsmoke_portable
  swift run pebsmoke-portable --require-suite persistence   # expect PASS (InMemoryWorldStore is yours)
  swift run pebsmoke-portable --require-suite math          # expect FAIL — the spec is red
  swift run pebsmoke-portable --require-suite audio         # expect FAIL
  swift run pebsmoke-portable --require-suite sockets       # expect FAIL
  swift run -c release pebsmoke-deterministic --require-suite deterministic
  git diff --exit-code -- goldens/

Commit once: \`port: stage 1 — API commit (WorldStore, MonotonicClock, Mat4f, socket ABI) + failing suites\`
Return the sha.
`, { label: 'api-commit', phase: 'API', model: 'opus', effort: 'medium', schema: SCHEMA })

if (!api || !api.sha) { log('API commit failed — nothing to fan out from'); return { aborted: 'api', recover, api } }
log(`API commit ${api.sha.slice(0, 8)} — lanes will merge this forward`)

// ---------------------------------------------------------------- Stage 2 + 3 concurrent (P3)

phase('Build')

// P4: leaf lanes build only their own target, in debug. Only the integrator builds the world.
const LEAF = [
  { label: 'math-time', target: 'PebbleCore', suite: 'math',
    owns: 'Sources/PebbleCore/Core/**',
    task: `Make Suite_Math green. Rewrite MathX.swift to drop \`import simd\`: replace simd_length/
      length_squared/distance/distance_squared/dot/cross/normalize/simd_float4x4/matrix_identity_float4x4
      and all \`m[i][j]\` indexing with the Mat4f the API commit landed. \`Vec3 = SIMD3<Double>\` may stay —
      SIMD3 is stdlib, not simd. Results must be bit-identical for the values the goldens exercise.
      If Sources/Pebble stops building, fix it inside MathX by preserving the old API surface, NOT by
      editing the app.` },

  { label: 'persistence', target: 'PebbleStoreSQLite', suite: 'persistence',
    owns: 'Sources/PebbleCore/Game/**, Sources/PebbleStoreSQLite/**, Sources/pebsmoke/main.swift, Sources/pebserver/main.swift, Sources/Pebble/main.swift',
    task: `Get \`import SQLite3\` out of PebbleCore. Move the implementation to
      Sources/PebbleStoreSQLite/SQLiteWorldStore.swift as \`public final class SQLiteWorldStore: WorldStore\`
      with a THROWING \`init(paths:) throws\`. Kill the fatalError on open-failure and the print-and-continue
      handling in exec/prepare — surface SQLiteWorldStoreError. Keep WAL, keep the mutex, keep the schema
      and the legacy saves/ import behaviour byte-identical. Delete SaveDB and update the three executables
      to inject \`{ try SQLiteWorldStore(paths: $0) }\`. Swap Saves.swift's chunk container onto the shared
      VCK1 codec in PebbleCoreBase and prove byte-identity. \`pebserver --help --data-dir X\` must still
      create ZERO files.` },

  { label: 'audio-core', target: 'PebbleAudioCore', suite: 'audio',
    owns: 'Sources/PebbleAudioCore/**',
    task: `Make Suite_Audio green. Read Sources/Pebble/Audio.swift (1232 lines, AVFoundation) for the real
      requirements — voice count, positional model, buses, ducking — then implement a portable mixer:
      AudioTypes, WavDecoder (RIFF s16le/u8/f32, mono+stereo, bounds-checked, throws never traps),
      Resampler (integer + fractional phase accumulator, no Double drift), Mixer (fixed voice pool,
      \`render(into:frames:)\` PURE and deterministic, no locks inside render), AudioSink protocol with
      NullAudioSink and OfflineAudioSink. Do NOT modify Audio.swift. Mark null/offline sinks as test
      harnesses in a comment.` },

  { label: 'sockets', target: 'PebblePlatformNative', suite: 'sockets',
    owns: 'Sources/CPebblePlatform/**, Sources/PebblePlatformNative/**',
    task: `Make Suite_Sockets green. Implement the socket ABI the API commit declared.
      \`#if defined(_WIN32)\` -> Winsock2 (WSAStartup via InitOnceExecuteOnce, closesocket, SOCKET);
      \`#else\` -> POSIX (sys/socket.h, netdb.h, poll.h). getaddrinfo both ways, prefer AF_INET6 with
      IPV6_V6ONLY=0 and fall back to AF_INET. SO_REUSEADDR on listeners. Suppress SIGPIPE (MSG_NOSIGNAL /
      SO_NOSIGPIPE). Handle EINTR. Timeouts via poll/WSAPoll. \`pb_socket_close\` idempotent, no double free.
      Make \`pb_platform_last_error\` thread-local (\`_Thread_local\` / \`__declspec(thread)\`) — today it is a
      global char buffer, which is a data race. Compile clean under -Wall -Wextra. Add a safe Swift wrapper
      in PebblePlatformNative with a deinit that closes exactly once.
      If you need \`.linkedLibrary("ws2_32", .when(platforms: [.windows]))\` in Package.swift, DO NOT add it —
      say so in \`blocked\` and the integrator will.` },
]

const leafLanes = LEAF.map((l) => () =>
  agent(`${RULES}${rebase(api.sha)}

FILES YOU OWN (nothing else — anything outside this is another lane's and will conflict):
  ${l.owns}

${l.task}

The suite \`Suite_${l.suite[0].toUpperCase()}${l.suite.slice(1)}.swift\` was written by a DIFFERENT agent and is
currently RED. Do not edit it to make it pass — implement until it passes. If a check is genuinely wrong,
say so in \`blocked\` with your reasoning; do not silently weaken it.

VERIFY (debug only — the integrator owns release builds and the full graph):
  swift build --target ${l.target}
  swift run pebsmoke-portable --require-suite ${l.suite}     # must exit 0 with a nonzero check count
  swift run pebsmoke-portable --require-suite ${l.suite}     # twice: no flake, no port reuse
  git status --porcelain    # only the files you own
${l.label === 'math-time' || l.label === 'persistence' ? '  swift build --target Pebble   # you can break the app; prove you did not\n' : ''}`,
    { label: l.label, phase: 'Build', model: 'sonnet', effort: 'medium', isolation: 'worktree', schema: SCHEMA })
      .then((r) => (r ? { ...r, lane: l.label } : null)))

// The critical path. Six sequential steps, nothing else is on it, so it starts NOW and the leaf lanes
// run in its shadow. pipeline() — no barrier between stages.
const renderChain = () => pipeline(
  [{ slice: 'frame-builder' }],
  (item) => agent(`${RULES}${rebase(api.sha)}

CRITICAL PATH 1/2 — \`FrameBuilder\`. You own \`Sources/PebbleCore/Render/FrameBuilder.swift\` (new) only.

PebbleRenderABI already defines the neutral packet types (FramePacket, RenderPass, DrawItem, the vertex
and uniform layouts, ShaderManifest, the capture contract). Build the producer: walk the world/entity/
particle/UI state and emit a FramePacket. No MTL*, no NS*, no Vk*, no SDL types in the public API.

Draw order must be a TOTAL order — unstable draw order is the number one source of golden-screenshot
flake. Sort every DrawItem list by the ABI's documented sort key before emitting.

Add \`Suite_FrameBuilder\` checks into Suite_RenderABI.swift: same world state produces byte-identical
packets across two runs; a permuted input produces the same sorted draw sequence; no packet references a
resource handle it did not declare.

VERIFY:
  swift build --target PebbleCore
  swift run pebsmoke-portable --require-suite renderabi
  swift build --target Pebble        # unchanged, still green
  git diff --exit-code -- goldens/`,
    { label: 'frame-builder', phase: 'Build', model: 'opus', effort: 'medium', isolation: 'worktree', schema: SCHEMA }),

  (prev) => prev && prev.sha ? agent(`${RULES}${rebase(prev.sha)}

CRITICAL PATH 2/2 — Metal consumes neutral packets. THIS IS THE MOST DANGEROUS AGENT IN THE PORT.
It can silently regress the shipped macOS product. It shares a commit with nothing else.

Rewire Sources/Pebble/WorldRenderer.swift, EntityRendererM.swift, ParticlesM.swift, GearRenderM.swift and
the UI/HUD path to render from the FramePacket the FrameBuilder emits, instead of reaching into GameCore.
Do NOT whole-file move anything before the dependency is inverted. Metal stays the default backend.

Before you change anything, capture the baseline:
  swift build -c release --target Pebble
  <fixed-seed screenshot via PEBBLE_AUTOLOAD=1 + PEBBLE_NEWWORLD, save under artifacts/porting/>
After:
  same screenshot, same seed, diff against the baseline. Any visible delta is a REGRESSION, not an
  improvement. Report the pixel delta and the paths in \`verification\`.

VERIFY:
  swift build -c release --target Pebble
  tmp=$(mktemp -d); PEBBLE_CI=1 PEBBLE_DATA_DIR="$tmp/data" swift run -c release pebsmoke -- --data-root "$tmp/data" --goldens-dir "$PWD/goldens"
  git diff --exit-code -- goldens/
  fixed-seed screenshot matches baseline`,
    { label: 'metal-consume', phase: 'Build', model: 'opus', effort: 'medium', isolation: 'worktree', schema: SCHEMA }) : null,
)

// leaf lanes and the render chain run concurrently. No barrier between them.
const built = await parallel([...leafLanes, () => renderChain().then((r) => r[0])])

const landed = built.filter(Boolean).filter((r) => r.sha && r.sha.length >= 7)
const lost = built.length - landed.length
if (lost) log(`${lost} agent(s) produced no commit — nothing merged from them`)
log(`${landed.length} commits to merge: ${landed.map((r) => (r.lane || 'render') + '@' + r.sha.slice(0, 8)).join(' ')}`)

const carried = landed.flatMap((r) => (r.blocked || []).map((b) => `[${r.lane || 'render'}] ${b}`))
if (carried.length) log('carried blockers:\n' + carried.map((b) => '  - ' + b).join('\n'))

// ---------------------------------------------------------------- Stage 4: integrate

phase('Integrate')

const integration = await agent(`${RULES}

TASK: Stage 4 — integrate. Work directly in ${REPO} on \`main\`. Under the v2 ownership map these diffs are
disjoint, so a conflict is a BUG IN THE MAP, not a normal event. If one occurs, resolve it keeping both
lanes' intent and report the overlap so the map can be fixed.

Merge in order, by sha:
${landed.map((r) => `  ${r.sha}  ${r.lane || 'render'} — ${r.summary.split('\n')[0].slice(0, 100)}`).join('\n')}

Lane-reported blockers you must resolve or carry:
${carried.length ? carried.map((b) => '  - ' + b).join('\n') : '  (none)'}

Then, and only here, build the world:
  swift build -c release --target PebbleCoreBase
  swift build -c release --target PebbleCore
  swift build -c release --target Pebble
  swift build -c release --target pebserver
  swift build -c release --target pebsmoke
  swift build -c release --target pebsmoke_portable
  swift run -c release pebsmoke-deterministic --require-suite deterministic
  swift run -c release pebsmoke-portable --require-suite math --require-suite vck1 --require-suite protocol \\
      --require-suite persistence --require-suite renderabi --require-suite codecs --require-suite audio --require-suite sockets
  swift run -c release pebsmoke-portable --require-suite doesnotexist       # MUST exit nonzero
  tmp=$(mktemp -d); PEBBLE_CI=1 PEBBLE_DATA_DIR="$tmp/data" swift run -c release pebsmoke -- --data-root "$tmp/data" --goldens-dir "$PWD/goldens"
  git diff --exit-code -- goldens/
  git grep -nE 'import (AppKit|Metal|MetalKit|QuartzCore|AVFoundation|Network|SQLite3|Darwin|simd|CoreGraphics|ImageIO|Compression)' -- Sources/PebbleCore Sources/PebbleCoreBase Sources/PebbleRenderABI Sources/PebbleCodecs Sources/PebbleAudioCore Sources/PebblePlatformNative Sources/pebsmoke_portable Sources/pebsmoke_deterministic
  git grep -nE 'GameCore\\(\\)|SocialStore\\.shared|vcSupportDir' -- Sources
The last two greps must print nothing.

TEMP-ROOT AUDIT — prove it, do not assert it:
  h=$(mktemp -d); d=$(mktemp -d); HOME="$h" PEBBLE_CI=1 PEBBLE_DATA_DIR="$d" swift run -c release pebsmoke -- --data-root "$d" --goldens-dir "$PWD/goldens"; find "$h" -type f
\`find "$h" -type f\` must print nothing. Repeat for \`pebserver --help --data-dir\`.

If a lane asked for \`.linkedLibrary("ws2_32", .when(platforms: [.windows]))\`, add it now.

Then extend .github/workflows/portability.yml: add PebbleCore + pebsmoke_portable to the WINDOWS build
list and require all eight suites there — but ONLY if PebbleCore genuinely compiles free of Apple imports.
If it does not, leave the job alone and say why in \`blocked\`. Never add a job you believe will fail.

Update docs/windows-support-matrix.md to what CI actually proves. Rows compiled AND run on Windows CI
become \`experimental\`. Nothing becomes \`shipped\` — no Pebble binary has ever executed on Windows hardware.
Vulkan/SDL/miniaudio/packaging stay \`blocked\` until their gates exist. Cite the CI job name as evidence.

Commit once: \`port: wave 1b — portable math/persistence/audio/sockets, FrameBuilder, Metal on neutral packets\`
`, { label: 'integrate', phase: 'Integrate', model: 'opus', effort: 'medium', schema: SCHEMA })

if (!integration || !integration.sha) { log('integration failed — main may be mid-merge'); return { aborted: 'integrate', recover, api, landed, integration } }

// ---------------------------------------------------------------- Stage 5: review

phase('Review')

const FINDING = {
  type: 'object', additionalProperties: false, required: ['blockers', 'nonBlocking', 'verdict'],
  properties: {
    verdict: { type: 'string', enum: ['pass', 'fail'] },
    blockers: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['file', 'line', 'summary', 'failureScenario', 'proof'],
        properties: { file: { type: 'string' }, line: { type: 'integer' }, summary: { type: 'string' },
          failureScenario: { type: 'string' }, proof: { type: 'string' } },
      },
    },
    nonBlocking: { type: 'array', items: { type: 'string' } },
  },
}

// breadth over depth: many narrow lenses at low effort beat few broad ones at high
const LENSES = [
  ['overclaim', `Prove the branch claims capability it does not have. A support-matrix row marked
     shipped/experimental with no CI job that both COMPILES and RUNS it. A CI step that passes without
     executing anything: \`|| true\`, \`continue-on-error\`, a swallowed exit code, an \`if:\` that is never
     true, a suite with zero checks. Run \`swift run pebsmoke-portable --require-suite doesnotexist\` — it
     MUST exit nonzero. README or PORTING text asserting a working Windows path. No Pebble binary has ever
     run on Windows.`],
  ['data-safety', `Can any path write outside the injected data root? Grep applicationSupportDirectory,
     NSHomeDirectory, FileManager.default.urls(, Bundle.main, currentDirectoryPath. Then PROVE it: run the
     full smoke with HOME set to an empty temp dir and \`find\` it afterwards. Is PEBBLE_REGOLD rejected in
     all three harnesses BEFORE any write — an env check after a createDirectory is a bug. Any surviving
     GameCore(), SocialStore.shared, eager store construction at file scope, or fatalError on a recoverable
     path in a non-app target?`],
  ['untrusted-input', `Every new parser eats untrusted bytes: network frames, PNG, ZIP, WAV, VCK1 blobs.
     Try to crash them. Look for \`!\`, unchecked array subscripts, Data indexed from 0 instead of startIndex,
     withMemoryRebound/assumingMemoryBound on unaligned bytes, unchecked multiplication on a length,
     allocation sized from an attacker-controlled count. Where you can, build a failing input and run it
     through the suite binary. A reproduction is worth ten hunches.`],
  ['c-abi', `Sources/CPebblePlatform/CPebblePlatform.c. Is pb_platform_last_error thread-local? Is
     pb_socket_close idempotent — any use-after-free on double close? Unchecked getaddrinfo result, missing
     freeaddrinfo? Does the Winsock branch parse as a compiler would read it (it cannot compile here)? Do
     the struct_size / layout asserts actually run? Does any handle leak on an error path?`],
  ['macos-regression', `The shipped product is the macOS Metal app. Mat4 changed from simd_float4x4 to a
     hand-rolled Mat4f — verify 64 bytes, column-major, and that WorldRenderer/*M.swift still hand the same
     bytes to setVertexBytes. A row/column-major flip compiles fine and renders garbage. Compare against
     \`git show <old>:Sources/PebbleCore/Core/MathX.swift\`. EngineServices became throwing and SaveDB became
     \`any WorldStore\` — did an existential land in a per-frame chunk save/load loop? Did an error path become
     a silent \`try?\`? Do NetSession callbacks still hop to the main queue in the AppKit app? Build and run it.`],
  ['determinism', `Does any encode path iterate a Set or Dictionary unsorted? Is DrawItem's sort key a
     TOTAL order — does a permuted array sort back to the identical sequence? Does AudioMixer.render depend
     on hash order or wall-clock? Does FrameBuilder emit byte-identical packets from identical state?
     Two GameCore instances must not share mutable state.`],
]

const reviewed = (await parallel(LENSES.map(([key, lens]) => () =>
  agent(`Adversarial reviewer on the Pebble Windows port. Repo ${REPO}, \`main\` at ${integration.sha}.
FIND REAL DEFECTS. Do not summarize. The implementing agents were rewarded for reporting success; assume
they cut corners. In the previous wave two lanes reported verifications they could not have executed.

Ground truth: MoltenVK 1.4.1 works here and reports Vulkan 1.2. glslc/spirv-val/spirv-cross are on PATH.
\`-lSDL2\` links a shim. No Pebble binary has ever run on Windows.

Diff under review: \`git diff ${api.sha}~1..HEAD\`

LENS — ${key.toUpperCase()}: ${lens}

RULES
- Every finding needs proof: a command you ran, or the exact code you read. No proof, no finding.
- BLOCKER only if it (a) breaks the macOS app, (b) writes real user data, (c) claims capability that does
  not exist, (d) can crash or corrupt on untrusted input, or (e) makes a required suite pass vacuously.
  Everything else is nonBlocking.
- You may build and run. You may NOT edit, commit, or push.
- Zero blockers is a legitimate answer. Do not manufacture findings. But \`verdict: pass\` means you are
  staking your name on this branch being safe to ship.`,
    { label: `review:${key}`, phase: 'Review', model: 'opus', effort: 'low', schema: FINDING })
))).filter(Boolean)

const found = reviewed.flatMap((r) => r.blockers)
log(`${found.length} candidate blockers from ${reviewed.length} lenses`)

const confirmed = found.length ? (await parallel(found.map((b) => () =>
  agent(`REFUTE this claimed blocker. Repo ${REPO}.

  ${b.file}:${b.line}
  claim: ${b.summary}
  fails when: ${b.failureScenario}
  reviewer's proof: ${b.proof}

Read the code. Try to reproduce it with a real command. If the reviewer misread, if the scenario is
impossible, if a guard elsewhere prevents it, or if a test already covers it — REFUTED.
Default to refuted=true when uncertain. Do not edit files.`,
    { label: `refute:${b.file.split('/').pop()}:${b.line}`, phase: 'Review', model: 'sonnet', effort: 'low',
      schema: { type: 'object', additionalProperties: false, required: ['refuted', 'why'],
        properties: { refuted: { type: 'boolean' }, why: { type: 'string' } } } })
    .then((v) => (v && !v.refuted ? { ...b, why: v.why } : null))
))).filter(Boolean) : []

log(`${confirmed.length}/${found.length} survived refutation`)

const fix = confirmed.length ? await agent(`${RULES}

Close these P0 blockers on \`main\` at ${integration.sha}. Fix ONLY these. Do not refactor anything else.

${confirmed.map((b, i) => `BLOCKER ${i + 1} — ${b.file}:${b.line}
  ${b.summary}
  fails when: ${b.failureScenario}
  proof: ${b.proof}
  survived refutation because: ${b.why}
`).join('\n')}

For each: first write a check into the relevant pebsmoke-portable suite that FAILS before your fix and
PASSES after — run it both ways and paste both outputs. Then fix it. If a blocker is a false positive once
you read the code, say so in \`blocked\` with reasoning. Do not invent a fix for a bug that is not there.

Re-run the full gate (release builds, all eight suites, full smoke under a temp root, goldens diff).
Commit once: \`port: wave 1b review fixes\`.
`, { label: 'fix', phase: 'Review', model: 'opus', effort: 'medium', schema: SCHEMA }) : null

return {
  recover: { sha: recover.sha, unreproducible: recover.blocked },
  apiCommit: api.sha,
  landed: landed.map((r) => ({ lane: r.lane || 'render', sha: r.sha, blocked: r.blocked })),
  lostAgents: lost,
  integration: integration.sha,
  blockersFound: found.length,
  blockersConfirmed: confirmed.length,
  confirmedBlockers: confirmed.map((b) => `${b.file}:${b.line} — ${b.summary}`),
  fix: fix ? { sha: fix.sha, blocked: fix.blocked } : null,
  nonBlocking: reviewed.flatMap((r) => r.nonBlocking),
  carriedBlockers: carried,
  nextWave: 'render chain slices 3-6: Vulkan bootstrap (pebvk headless) -> passes -> render CI. Gated on the Metal-consume screenshot diff.',
}
