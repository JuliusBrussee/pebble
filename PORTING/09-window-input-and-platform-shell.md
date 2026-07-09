# 09 — Window, Input, Clipboard, File Dialogs, and App Shell

## Scope

Files: `Sources/Pebble/main.swift`, `MenusM.swift`, `LanScreens.swift`, `Skins.swift`, `ScreensM.swift`, `UIManagerM.swift`, `HudM.swift`.

Goal: extract platform shell services and implement AppKit plus SDL/native adapters without breaking current input/UI behavior.

## Current blockers

- `main.swift` combines NSApplication, NSWindow, MTKView, events, menus, GameCore, renderer, UI, audio, screenshots, and full-screen behavior.
- UI/screens directly call AppKit/QuartzCore/global renderer state.
- Portable UI still depends on Metal-backed `UICanvas` until module 08/06 land.
- Windows visible client depends on renderer, data-root, network, codec, and clock seams.

## Services to introduce

- `WindowService`: title, close/quit, fullscreen, drawable size, content scale, focus.
- `CursorService`: capture/release, raw/relative mode, show/hide.
- `ClipboardService`: UTF-8 text get/set.
- `FileDialogService`: open/save PNG with cancel/error results.
- `ClockService` and `Scheduler`.
- `ResourceLocator` / data root provider.
- `AppCommands`: quit, fullscreen, relayout, screenshot/test actions, renderer progress, skin changed.
- Normalized `PlatformEvent` model.

## Input contract

Preserve current behavior unless a change is explicitly tested:

- Keybind strings like `KeyW`, `Space`, `F3`, arrows, numpad names.
- Physical keys separate from text input.
- Repeat filtering: world ignores repeats; screen behavior remains documented.
- Modifiers: Shift, Control, Alt/Option, Command/Super, `ctrlOrCmd`.
- Mouse buttons: left 0, middle 1, right 2.
- UI coordinates: top-left GUI units using drawable pixels / GUI scale.
- Captured world input uses relative deltas; screens use absolute coordinates.
- Focus loss clears held input, releases pointer, restores cursor, and opens Pause if in world.

## Plan

1. Freeze current AppKit behavior in a matrix: keys, modifiers, repeats, text, paste, scroll, capture, fullscreen, focus, resize, `PEBBLE_*` hooks.
2. Add platform-neutral service/event protocols in a portable target.
3. Add fake shell/null renderer/null audio harness for tests.
4. Replace QuartzCore timing in UI/HUD/screens with injected frame time from module 03.
5. Extract `PebbleAppRuntime` from `AppDelegate`: GameCore, UI stack, HUD, HostBridge behavior, screenshot/test policy.
6. Replace direct platform calls in screens: quit, fullscreen, GUI relayout, loading progress, clipboard, file dialogs, skin apply/reset.
7. Implement AppKit adapter first and verify parity.
8. Implement SDL/native adapter for Windows: high-DPI window, event pump, scancodes, text input, relative mouse, clipboard, fullscreen, cursor, focus, resize, file dialogs/fallback.
9. Expose Vulkan surface/required extensions through native C ABI for module 07.

## Verification gates

- Static import gate: portable runtime/UI has no AppKit, Metal, QuartzCore, CoreGraphics, ImageIO, AVFoundation, Network, `NS*`, `MTL*`, or `NW*`.
- AppKit and SDL produce identical internal key strings for defaults.
- Text, paste, modifiers, mouse capture, scroll, DPI, fullscreen, focus loss, resize, GUI scale, and skin dialogs pass tests.
- Mac app remains behavior-compatible.
- Windows SDL shell can run fake/null-renderer smoke before real Vulkan is ready.

## Done criteria

The AppKit shell is thin, the portable runtime talks only to services/backends, and Windows has a tested SDL/native shell path ready for Vulkan/audio/network modules.
