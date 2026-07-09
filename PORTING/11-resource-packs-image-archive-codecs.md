# 11 — Resource Packs, PNG/Image Codecs, Zip/Archive Codecs, and Skins

## Scope

Files: `Sources/Pebble/ResourcePacks.swift`, `Skins.swift`, `PhotoBooth.swift`, `WorldRenderer.swift` resource upload touchpoints, and `packaging/` assets.

Goal: replace Apple-only image/archive/resource handling with portable services that produce backend-neutral RGBA data for Metal and Vulkan.

## Current blockers

- `ResourcePacks.swift` imports AppKit, Compression, CoreGraphics, ImageIO.
- `Skins.swift` imports AppKit, ImageIO, UniformTypeIdentifiers.
- `PhotoBooth.swift` uses AppKit/ImageIO/Metal.
- Resource pack UI (`PackUI`) owns `MTLTexture`.
- Default asset lookup assumes app bundle or repo `packaging/` fallback.

## Target architecture

- `ImageCodec`: decode PNG to straight RGBA8; encode RGBA8 to PNG for skins/capture.
- `ArchiveCodec`: read resource-pack ZIPs with stored/deflate entries, path normalization, size caps, and no extraction.
- `ResourceLocator`: macOS bundle, Windows package `assets/`, dev repo fallback.
- `ResourcePackCatalog(paths:, locator:)`: default pack restore, discovery, folder/zip indexing.
- `PackAtlasResult` and UI/font/entity/title/sun/moon payloads are plain pixels/metadata, not GPU textures.
- Renderer backend owns upload/invalidation.

Portable codec candidates can be lodepng/miniz or equivalent pinned C libraries, but final implementation must record versions and licenses.

## Plan

1. Add `ResourceLocator` and route default pack restore through it.
2. Add path-aware `ResourcePackCatalog`; remove hard-coded `vcSupportDir()` calls from shared pack code.
3. Replace string path slicing for folder packs with URL/path-component relative normalization and `/` pack-internal separators.
4. Add `ImageCodec` with strict dimension/memory caps, RGBA8 output, no accidental premultiply/sRGB conversion.
5. Add `ArchiveCodec` with caps for file count, compressed size, decompressed size, central directory sanity, and zip-bomb protection.
6. Convert `decodePNG`, `encodePNG`, skin import/export, pack texture loads, and capture encoding to codec services.
7. Convert `PackUI` from Metal texture owner to plain `PackUISheets` pixels + sheet metadata + font widths.
8. Convert sun/moon/title/logo/entity texture payloads to plain image uploads.
9. Keep file dialogs in module 09; this module only consumes selected URLs/paths.
10. Add corrupt/oversized fixture tests.

## Verification gates

- Default Faithful pack self-restores if deleted.
- Zipped and folder resource packs are discovered.
- Bundled Faithful builds atlas with nonzero applied tiles/items and animation frames.
- GUI sheets/font widths load and render through backend-neutral payloads.
- Custom skin import/export round-trips PNG and rejects invalid dimensions/formats.
- Capture writes valid PNG using portable encoder.
- Corrupt PNG, oversized PNG, corrupt zip, unsupported compression, path traversal, and zip bomb fail safely.

## Done criteria

Resource packs, skins, UI sheets, title/sun/moon assets, and captures no longer require Apple codecs or Metal types in shared code.
