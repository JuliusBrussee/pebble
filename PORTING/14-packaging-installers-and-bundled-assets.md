# 14 — Packaging, Installers, Bundled Assets, and Distribution

## Scope

Files: `pebble`, `packaging/`, `packaging/Info.plist`, `Package.swift`, `README.md`, release workflows.

Goal: create repeatable, verified macOS and Windows artifacts. Windows packaging is blocked until real Windows targets and native outputs exist.

## Current blockers

- `pebble` is a macOS source-checkout Bash installer.
- Package is macOS-only and client imports AppKit/Metal.
- Windows binaries must include Swift runtime/ICU/MSVC/native DLL closure or document accepted prerequisites.
- Dynamic libraries must be placed where OS loaders search: Windows beside `.exe`, macOS in `Contents/Frameworks` with rpaths/signing.
- Package smoke must use temp data root (`PEBBLE_DATA_DIR`), requiring module 04.

## Artifact strategy

- macOS: `Pebble-macos-arm64-<version>.zip` containing `Pebble.app` and docs. Keep Metal path default.
- Windows: `Pebble-windows-x64-<version>.zip` portable folder, no installed Swift toolchain required.
- No MSI/winget/auto-updater initially.
- CLI semantics differ by context: source checkout vs packaged app.

## Packaging manifest

Add machine-readable `packaging/package-manifest.json` or equivalent with:

- version source (`PEBBLE_VERSION` or generated metadata),
- platform/arch artifact names,
- asset inventory,
- license triggers,
- native dependency list and placement,
- checks: version match, plist keys, licenses, dependency closure, no repo resource dependency, temp-root smoke.

## macOS layout

`Pebble.app/Contents/` should include:

- `MacOS/Pebble`
- `Info.plist`
- `Resources/AppIcon.icns`, `logo.png`, `title-bg.png`, `Faithful 32x - 1.20.1.zip`, licenses/notices
- `Frameworks/` only for dynamic native deps such as SDL/MoltenVK if enabled later

Preserve:

- `CFBundleShortVersionString` matching `PEBBLE_VERSION`
- `LSMinimumSystemVersion`
- local-network/Bonjour keys
- ad-hoc signing for local install, optional Developer ID/notarization for release

## Windows layout

Portable zip:

- `Pebble.exe`
- optional `pebserver.exe`, optional `pebsmoke.exe`
- required `.dll` files beside executables unless absolute-loading is intentionally implemented
- `assets/` with logo, title background, Faithful zip
- `licenses/` with MIT, Faithful, third-party notices
- `README-WINDOWS.txt`
- optional wrappers `pebble.cmd` / `pebble.ps1`

Do not ship MoltenVK on Windows. Windows Vulkan uses native Vulkan loader/driver behavior.

## Plan

1. Inventory `packaging/` assets and classify runtime vs release-site vs excluded.
2. Add/update third-party notices: MIT, Faithful, fdlibm/Sun, and future SDL/Vulkan/MoltenVK/miniaudio/SQLite/codecs.
3. Add version metadata gate: plist version matches `PEBBLE_VERSION`.
4. Define resource-root and data-root contracts for packaged apps.
5. Refactor macOS `pebble` into stages: build, stage-app, stage-native, validate-plist, sign, verify, install.
6. Add package verifier for content, dependency closure, licenses, plist, executable bits, codesign, no source checkout paths.
7. Add macOS release zip path and launch smoke with repo unavailable and temp data root.
8. After Windows port modules land, add Windows portable package staging including Swift/native DLL closure.
9. Add Windows package smoke on a clean environment with no source checkout and no installed Swift dependency unless explicitly documented.
10. Create CI/release workflows that upload artifacts and SHA256 checksums.
11. Update README support/install docs only after gates pass.

## Verification gates

- macOS app bundle contains required executable, plist, icon, assets, default pack, Faithful license, MIT license, notices.
- `CFBundleShortVersionString` matches `PEBBLE_VERSION`.
- macOS local-network/Bonjour plist keys present.
- `otool -L`/codesign checks clean for release mode.
- Windows package contains executables, assets, licenses, Swift runtime/native dependency closure.
- Packaged app launches without repo checkout.
- Default Faithful pack self-restores from packaged resources.
- Package smoke uses temp data root via `PEBBLE_DATA_DIR`.

## Done criteria

Release artifacts are generated from a manifest, verified mechanically, contain required assets/licenses/dependencies, and accurately document source vs packaged workflows on each platform.
