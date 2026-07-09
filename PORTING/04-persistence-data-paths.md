# 04 — Persistence, SQLite, Settings, and User Data Paths

## Scope

Files: `Sources/PebbleCore/Game/Saves.swift`, `Settings.swift`, `GameCore.swift`, `Sources/PebbleCore/Net/Social.swift`, `Sources/Pebble/Skins.swift`, `Sources/Pebble/ResourcePacks.swift`.

Goal: make storage explicit, injectable, and Windows-ready while preserving existing macOS save locations and formats.

## Current blockers

- `vcSupportDir()` always uses macOS Application Support.
- `GameCore` constructs `SaveDB()` before callers can inject a temp root.
- `SaveDB` imports ambient `SQLite3`; Windows needs explicit SQLite packaging.
- `SocialStore.shared` is a singleton loaded from the default support dir.
- VCK1 save/wire chunk encoding is duplicated and uses host-memory assumptions.

## Target architecture

Add `PebbleDataPaths` resolving:

1. explicit app/server/test URL,
2. `PEBBLE_DATA_DIR`,
3. platform default: macOS `~/Library/Application Support/Pebble`, Windows `%LOCALAPPDATA%\\Pebble` or the project-chosen equivalent.

Add instance stores:

- `SettingsStore(paths:)`
- `SocialStore(paths:, clock:)`
- `SQLiteWorldStore(paths:)` (temporary `typealias SaveDB` allowed)

`GameCore` receives stores/services in init. The legacy `GameCore()` can remain as a macOS/default convenience.

## Plan

1. Add `PebbleDataPaths` with tests for explicit/env/default roots.
2. Refactor settings/keybinds to `SettingsStore`, preserving JSON names, defaults, clamping, sorted pretty output, and key strings.
3. Refactor social JSON to instance store; remove `SocialStore.shared` from core/network/smoke paths.
4. Convert `SaveDB` to `SQLiteWorldStore(paths:)`, preserving tables, WAL intent, busy timeout, delete semantics, and migration.
5. Vendor/package SQLite explicitly through a SwiftPM C/system-library target; no ambient `SQLite3` assumption on Windows.
6. Centralize VCK1 codec for save DB and network chunk payloads. Use explicit little-endian, unaligned-safe reads, overflow checks, and size caps before allocation.
7. Make legacy `saves/` migration root-local, idempotent, and marker-based with collision-safe backups.
8. Wire app, `pebserver --data-dir`, skins, and resource packs through `PebbleDataPaths`.
9. Ensure all smoke/CI tests fail early if no temp data root is configured.

## Verification gates

- Create/list/load/delete world under an injected temp root.
- Save modified chunk, exit, reload from a fresh `GameCore`, verify blocks/entities/block entities.
- Inject a failed chunk batch write and verify dirty chunks are re-marked.
- Settings/keybinds/social JSON round-trip under temp root.
- Legacy migration runs once, writes marker, never deletes source files.
- VCK1 byte fixtures validate little-endian and malformed/oversized decode safety.
- Windows links project-owned SQLite with thread-safety diagnostics.

## Done criteria

No persistence path touches real user data unless explicitly using platform defaults; storage is injectable; SQLite and VCK1 are portable and tested.
