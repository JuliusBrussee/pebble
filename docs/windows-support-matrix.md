# Windows support matrix

Implementation status from current source tree. Work in this porting batch was intentionally not built or run; new rows remain `experimental` until CI evidence exists.

| Capability | macOS | Windows | Status | Current source evidence |
|---|---|---|---|---|
| `PebbleCoreBase` | shipped | shipped | shipped | Existing selected-target CI |
| `PebbleCore` | shipped | experimental | experimental | Portable `Mat4f`; no active `Network`, `simd`, or `SQLite3` import; Windows CI job now selects target |
| `PebbleRenderABI` | shipped | experimental | experimental | Neutral resources, `FrameBuilder`, deterministic draw ordering, backend protocol |
| Metal renderer | shipped | unavailable | shipped on macOS | Chunk passes consume neutral `FramePacket`; remaining passes still being migrated |
| Vulkan bootstrap | experimental | experimental | experimental | `CPebbleVulkan`, Vulkan 1.2 instance/device, portability subset, validation positive control, offscreen clear/readback, PNG capture |
| Vulkan game passes | experimental | experimental | experimental | Chunk, shadow, animated entity, particle, sky/cloud, UI, offscreen composite, and capture paths execute from one frame packet in source; runtime proof still pending |
| `PebbleCodecs` | experimental | experimental | experimental | PNG, ZIP, DEFLATE; resource-pack consumer now uses portable codecs |
| `PebbleResources` | experimental | experimental | experimental | ZIP pack stack, custom/player/entity skins, and block atlas replacement use portable codecs |
| Native audio output | experimental | experimental | experimental | AudioUnit macOS and waveOut Windows C sinks; AVFoundation removed from default path |
| Portable audio mixer | experimental | experimental | experimental | Shared stereo voice mixer, spatial gain/pan, environment filtering, reverb, native sink facade |
| Apple networking | shipped | unavailable | shipped on macOS | Network.framework TCP and Bonjour adapter |
| Native TCP networking | experimental | experimental | experimental | Cross-platform C sockets plus `PebbleNetNative`; server installs it outside macOS |
| SQLite persistence | shipped | unavailable | shipped on macOS | Real `SQLiteWorldStore` isolated in `PebbleStoreSQLite` |
| Directory persistence | experimental | experimental | experimental | Portable atomic JSON/VCK1 `DirectoryWorldStore` below injected data root |
| Dedicated server | shipped | experimental | experimental | Windows target uses directory store and native TCP; selected by Windows CI |
| Full graphical app | shipped | experimental | experimental | SDL3 window/input/fullscreen/text, Vulkan frame loop, portable resources/audio, inventory/HUD, and screenshot paths are wired; runtime proof still pending |
| macOS package | shipped | unavailable | shipped on macOS | Manifest, licenses, version gate, codesign verification, zip and SHA256 path |
| Windows portable package | unavailable | experimental | experimental | Staging script compiles all shaders, locates SwiftPM output, closes SDL/Swift/ICU/MSVC runtime DLLs, verifies assets/licenses, and emits zip plus SHA256; runtime proof still pending |

No new `experimental` row is a release claim. Move to `shipped` only after target compiles and executes on matching CI runner.
