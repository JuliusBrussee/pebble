# Changelog

All notable changes to Pebble. Versions follow `MAJOR.MINOR.PATCH`; the
in-app version string comes from `PEBBLE_VERSION` (PebbleCore/Game/Saves.swift).

## 1.1.0 — 2026-07-02 — multiplayer (LAN + servers + friends), custom skins, speed slider

- **LAN multiplayer.** Play together on the same WiFi: the host presses
  Esc → *Open to LAN* in any world, friends pick *Multiplayer* on the title
  screen — no setup, worlds are discovered automatically (Bonjour). The host
  runs the real world; guests stream it live. Building, mining, combat, item
  pickup/drops, chat, day/night and weather all sync. Guests regenerate
  untouched terrain from the world seed, so joining is fast even on big
  worlds — only edited chunks travel over the wire. Covered by a full
  host+guest protocol/e2e test suite; singleplayer simulation is
  bit-identical to 1.0.3 (goldens unchanged).
  Known limits (for now): guests can't use the Nether/End portals, containers
  opened by guests don't live-sync, and commands are host-only.
- **Standalone servers (SMP).** `pebble serve --create "My SMP"` runs a world
  headless at 20 TPS with no host player — it stays up as long as the machine
  does. LAN players find it under Multiplayer automatically; internet players
  add its address under Multiplayer → *Servers* (port-forward 25585 on the
  server's router). Console commands: `list`, `say`, `save`, `stop`; Ctrl-C
  saves and exits cleanly.
- **Player identity + friends.** Every player gets a permanent random id
  minted on first launch (names can change, the id can't) — servers key
  inventories/positions by it, so renaming yourself keeps your stuff.
  Multiplayer → *Friends* lists your friends with live presence (online +
  one-click Join when their game is visible on the network) and *Recent
  Players* — everyone you've shared a world with — promotable to friends
  with one click. No accounts, no cloud: friends live in a local JSON.
- **Friend codes.** Multiplayer → Friends → *Copy My Code* gives you a short
  "PEB1…" code carrying your permanent identity. Swap codes over any chat app
  and paste with *Add By Code* — that's the whole friend request + accept,
  no world needed, no central servers involved.
- **Custom skins.** Title screen → *Skins…*: load any standard 64×64
  Minecraft skin PNG, save the current skin as a template to draw on, or go
  back to Steve. The second skin layer (hats/jackets) is baked onto the model.
- **Visible gear.** Worn armor now shows on player bodies (all six materials,
  real pack textures, following every walk/swing animation), held items render
  in hands as 3D extruded sprites with the vanilla edge-forward tilt, shields
  strap to the arm and raise when blocking — in third person and on every
  player in multiplayer (armor + offhand sync over the wire). Plus a proper
  first-person view: your arm (in your own skin) or held item swings, eats,
  draws bows and blocks in the bottom-right, vanilla-style.
- **Speed multiplier.** Options → Accessibility: run the whole simulation at
  0.5×–3× (singleplayer only; LAN worlds share one clock).

## 1.0.3 — 2026-06-27 — gameplay bug fixes (#11)

- **Mobs can no longer be hit while dying, and no longer dupe their drops.**
  A mob's death was processed every tick it kept taking damage during the
  ~1s death animation, re-running its loot drop (and slime splits / raid
  `bad_omen`) each time. Damage is now rejected once an entity enters its
  death animation, so loot drops exactly once. Re-baselined the entity goldens.
- **Tree leaves now drop saplings, sticks and apples when they decay.** Leaf
  decay destroyed the block without rolling its drop table; it now uses the
  normal natural-break path, matching what hand-breaking already dropped.
- **Beds now show a sleep overlay.** Sleeping faded straight to a frozen frame
  with no feedback; the screen now fades to black with a "Sleeping…" prompt,
  and Sneak/Esc leaves the bed.
- **Entities now cast a contact shadow.** A soft dark disc is projected onto
  the ground beneath living entities — including your own player in third
  person — and fades out as they rise off the ground.
- **The offhand can now use items, and shields block.** The use action falls
  back to the offhand when the main hand does nothing (food, shields, torches,
  throwables, …), and raising a shield now negates frontal melee, projectile
  and explosion damage.

## 1.0.2 — 2026-06-13 — bug fixes

- **Fixed `./pebble install` failing to compile on Swift 6.2.x.** The
  smooth-lighting arithmetic in `Mesher.swift` (plus a few other expressions)
  overran the Swift type-checker's budget and tripped integer-vs-`Double`
  inference, breaking the build partway through `./pebble install`. The
  expressions are now broken into single-operation typed locals; Pebble builds
  cleanly on every Swift 6.0–6.3 toolchain. Worldgen/mesh output is unchanged.
  This completes the #1 fix that 1.0.1 only partially addressed.
- **Fixed over-dark lighting in pits, holes and undersides.** Smooth lighting
  averaged in the zero skylight of solid neighbours, so the walls and floor of
  a freshly-dug hole rendered far darker than they should in daylight. Opaque
  neighbours now contribute the face light (standard vanilla smooth lighting);
  ambient occlusion still shades the corners. Re-baselined the mesh goldens.
- **The installer now checks your Swift version up front.** `./pebble install`
  needs Swift 6.0+; if you're below that it explains the fix and can install a
  current toolchain for you (via swiftly) instead of failing partway through a
  build.

## 1.0.1 — 2026-06-13 — minor bug fixes

- **Fixed a build failure on newer toolchains.** A literal-arithmetic
  expression in `Mesher.swift` overran the Swift type-checker's budget on some
  toolchains (e.g. Swift 6.2.3 / Xcode 26.3, M-series), making `./pebble
  install` fail to compile. The expressions are now hoisted into typed locals;
  worldgen/mesh output is byte-identical.
- **Fixed entity facing.** Mobs and the third-person player were rendered
  rotated by `-yaw` instead of the Minecraft `180° - yaw` convention, so they
  faced (and appeared to walk) backward. Render-side only.

## 1.0.0 — 2026-06-11 — first public beta

**This is a beta.** The engine is pinned by 456 golden checks, but a game of
this scope certainly has bugs we haven't found yet. Reports and fix PRs are
incredibly welcome: https://github.com/thebriangao/pebble/issues (the README
lists what to include).

The initial release. What ships:

- **A complete, native block-survival game for macOS** — ~45,000 lines of
  Swift + Metal, zero external dependencies, no game engine, no .xcodeproj.
- **Content**: 879 blocks, 1,188 items, 63 biomes, 100 entity types (55+ mobs
  with goal-based AI and A* pathfinding), 19 structure types (30+ variants), 39 enchantments,
  full brewing/enchanting/smithing/stonecutting/archaeology systems,
  advancements, raids, and villager trading.
- **Three dimensions** with working portals and full progression: overworld →
  nether (fortresses, bastions) → end (dragon fight, end cities, gateways),
  plus the Wither and the Warden.
- **Worldgen**: multi-noise climate sampling, spline terrain, 3D density caves,
  ravines, aquifers, vanilla-1.20 ore tables, snow lines, cave biomes
  including the deep dark.
- **Redstone**: wire networks, repeaters, comparators with container reading,
  pistons with quasi-connectivity, observers, hoppers, rails, sculk sensors.
- **Vanilla-exact player physics**, verified by independent derivations in the
  test suite (walk 4.317 b/s, sprint 5.612 b/s, jump apex 1.2522 blocks).
- **Synthesized audio**: every sound and all music generated in real time
  from oscillator recipes — zero audio files.
- **Faithful 32x textures built in** (self-restoring, credited, license
  included) — atlas art, `.mcmeta` animations, GUIs, fonts, entity skins,
  and sun/moon, loaded through Pebble's own zip reader. **Ultra graphics**:
  a built-in enhanced pipeline (SSAO, volumetric light, soft shadows, ACES).
- **Persistence**: single SQLite database (WAL) holding worlds, chunks
  (compact binary records), players, and advancements.
- **Quality**: 456 golden regression checks, all green; the engine is fully
  deterministic — identical seeds produce identical worlds on any machine,
  across releases; the build is warning-free; 200+ fps at full fancy settings
  on an Apple-silicon MacBook Air, ~2–4 s world loads.

### Known limitations

- Singleplayer only, for now — there is no networking code in 1.0.0.
- Elytra flight omits vanilla's dive-redirect term (look-pitch speed transfer);
  flight feel is otherwise vanilla-derived.
- Armor trims show in tooltips but not yet on worn armor.
- No resource-pack or shader-pack loading — the Faithful art and the ultra
  pipeline are built in; user-supplied packs are not a feature.
