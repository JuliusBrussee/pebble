# Native porting toolchain — macOS arm64 dev machine

Installed 2026-07-09 via Homebrew. Verified working, not just present.

## What is installed

| Tool | Version | Verified by |
|---|---|---|
| cmake | 4.3.4 | `cmake --version` |
| ninja | 1.13.2 | on PATH |
| pkgconf (`pkg-config`) | 2.5.1 | `pkg-config --modversion vulkan` → 1.4.350 |
| glslang (`glslangValidator`) | 16.3.0 | on PATH |
| shaderc (`glslc`) | 2026.2 | compiled a GLSL frag → SPIR-V |
| spirv-tools (`spirv-val`) | 1.4.350.1 | validated that SPIR-V |
| spirv-cross | 1.4.350.1 | cross-compiled that SPIR-V → MSL |
| molten-vk | 1.4.1 | enumerates as a real Vulkan device |
| vulkan-headers / vulkan-loader | 1.4.350.1 | `vkCreateInstance` → `VK_SUCCESS` |
| vulkan-tools (`vulkaninfo`) | 1.4.350.1 | reports GPU0 = Apple M3 Pro |
| vulkan-validationlayers | 1.4.350.1 | emits a real object-leak VUID (see below) |
| SDL2 + sdl2-compat | 2.32.10 / 2.32.70 | `pkg-config sdl2` |
| SDL3 | 3.4.10 | `pkg-config sdl3` |

`miniaudio` is not in Homebrew. It is a single public-domain/MIT-0 header, v0.11.25, staged at
`scratchpad/miniaudio.h` (95,864 lines). Lane E vendors it into `Sources/CPebblePlatform/vendor/`.

## Vulkan on this machine works, with portability

```
portability_enumeration_available=1
vkCreateInstance=0
physical_devices=1
  dev[0] Apple M3 Pro api=1.2.334
  dev[0] requires VK_KHR_portability_subset
```

So the MoltenVK path Lane D needs is real:
`VK_KHR_portability_enumeration` on the instance, `VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR`
in `VkInstanceCreateInfo.flags`, and `VK_KHR_portability_subset` **must** be enabled on the device.
MoltenVK reports only Vulkan 1.2, not 1.4 — do not request 1.3+ device features.

## Two traps that were fixed / must be worked around

### 1. The validation layer was silently inert

Homebrew ships `VkLayer_khronos_validation.json` with a bare `library_path`
(`libVkLayer_khronos_validation.dylib`, no directory separator). The loader hands that straight to
`dlopen`, which cannot find it, and then **skips the layer and still returns `VK_SUCCESS`**. You get
`Instance Layers: count = 1` and zero validation coverage.

Fixed by writing a corrected manifest with an absolute `library_path` into a directory the loader
actually searches:

```
/opt/homebrew/etc/vulkan/explicit_layer.d/VkLayer_khronos_validation.json
  → library_path = /opt/homebrew/lib/libVkLayer_khronos_validation.dylib
```

Now validation loads with **no environment variables at all**. Positive control — leaking a
`VkDebugUtilsMessengerEXT` across `vkDestroyInstance` produces:

```
VALIDATION: vkDestroyInstance(): VkInstance 0x103564ce0 has 1 leaked objects that have not been destroyed.
```

Any CI job that asserts "validation clean" must first assert that validation is *loaded*, by
deliberately triggering a VUID and requiring it to fire. A clean log from an unloaded layer is a
skip-as-pass.

The ICD needs no env var: the loader finds `/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json` on its
own. `VK_ICD_FILENAMES` / `VK_LAYER_PATH` are not required.

### 2. `-lSDL2` does not link SDL2

`sdl2` (2.32.10) and `sdl2-compat` (2.32.70) are both installed, and **sdl2-compat owns the symlinks**:

```
/opt/homebrew/lib/libSDL2.dylib      → Cellar/sdl2-compat/...
/opt/homebrew/lib/pkgconfig/sdl2.pc  → Cellar/sdl2-compat/...
/opt/homebrew/include/SDL2/SDL_version.h reports 2.32.70   (= compat, not real SDL2)
```

So `pkg-config --libs sdl2` links the SDL2-API-on-SDL3 shim. Recommendation: **target SDL3 directly**
(`pkg-config sdl3`). It is what is actually underneath either way, it has first-class
`SDL_Vulkan_CreateSurface`, and it ships official Windows VC dev packages. Avoid `sdl2-compat` as a
load-bearing dependency in a shipping product.

## Build flags

```sh
pkg-config --cflags --libs vulkan
#  -I/opt/homebrew/opt/vulkan-headers/include -L/opt/homebrew/Cellar/vulkan-loader/1.4.350.1/lib -lvulkan
pkg-config --cflags --libs sdl3
```

For a SwiftPM `systemLibrary` target, `pkgConfig: "vulkan"` works on macOS/Linux. Windows has no
pkg-config: the Vulkan SDK there exposes `%VULKAN_SDK%\Include` and `%VULKAN_SDK%\Lib\vulkan-1.lib`,
so the manifest needs a platform-conditional `unsafeFlags` / `linkedLibrary("vulkan-1")` branch.

## What is still missing for a Windows claim

- Nothing here proves anything about Windows. This is a macOS box with MoltenVK.
- Windows CI must install the LunarG Vulkan SDK and SDL3 VC devel packages before any Vulkan job can
  be more than "blocked" in `docs/windows-support-matrix.md`.
- No Windows machine has run this code. `experimental` is the ceiling until one does.
