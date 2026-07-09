# CPebblePlatform ABI Contract

`CPebblePlatform` is the C ABI boundary for future native platform work: Vulkan, SDL/windowing, miniaudio, sockets, and codecs.

Current status: skeleton only. All runtime capability flags are `0`; this is not evidence of shipped Windows, Vulkan, SDL, miniaudio, sockets, or codec support.

## Rules

- Public API is C-compatible and wrapped in `extern "C"` for C++ callers.
- Every extensible struct starts with `struct_size` and/or `abi_version`.
- Callers own memory they pass in.
- Native-owned handles, when added later, must be opaque and released through matching destroy functions.
- No allocation crosses the ABI without a paired release function.
- Strings are UTF-8. `pb_platform_last_error()` returns a thread-local pointer valid until the next `CPebblePlatform` call on the same thread.
- Future callbacks must carry `user_data`.
- Audio callbacks must not allocate, log, block, or call into Swift.
- Public signatures must not expose `Vk*`, `SDL*`, miniaudio, zlib, lodepng, Darwin, Win32, Objective-C, or C++ types.
- Any ABI-changing edit must update `PB_PLATFORM_ABI_VERSION` and layout tests.

## Current capabilities

`pb_platform_get_capabilities()` fills `PBPlatformCapabilities` with ABI metadata and all capability flags set to `0`.
