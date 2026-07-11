import Foundation
import PebbleCore
import PebbleCodecs
import PebbleNetNative
import PebblePlatformSDL
import PebbleRenderABI
import PebbleRendererVulkan
import PebbleResources

if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
    print("""
    pebble-win — Pebble SDL3 + Vulkan client

      pebble-win [--data-dir <path>] [--world <name-or-id>] [--seed <seed>]
                 [--autoload]
                 [--shader-dir <path>] [--resource-pack <zip>]
                 [--connect <host:port>] [--open-to-lan]
                 [--screenshot <png>] [--validation] [--fullscreen]
    """)
    exit(0)
}

func option(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

let scancodeMap: [Int: String] = [
    4: "KeyA", 5: "KeyB", 6: "KeyC", 7: "KeyD", 8: "KeyE", 9: "KeyF",
    10: "KeyG", 11: "KeyH", 12: "KeyI", 13: "KeyJ", 14: "KeyK", 15: "KeyL",
    16: "KeyM", 17: "KeyN", 18: "KeyO", 19: "KeyP", 20: "KeyQ", 21: "KeyR",
    22: "KeyS", 23: "KeyT", 24: "KeyU", 25: "KeyV", 26: "KeyW", 27: "KeyX",
    28: "KeyY", 29: "KeyZ", 30: "Digit1", 31: "Digit2", 32: "Digit3",
    33: "Digit4", 34: "Digit5", 35: "Digit6", 36: "Digit7", 37: "Digit8",
    38: "Digit9", 39: "Digit0", 40: "Enter", 41: "Escape", 42: "Backspace",
    43: "Tab", 44: "Space", 45: "Minus", 46: "Equal", 47: "BracketLeft",
    48: "BracketRight", 49: "Backslash", 51: "Semicolon", 52: "Quote",
    53: "Backquote", 54: "Comma", 55: "Period", 56: "Slash", 58: "F1",
    59: "F2", 60: "F3", 61: "F4", 62: "F5", 63: "F6", 64: "F7",
    65: "F8", 66: "F9", 67: "F10", 68: "F11", 69: "F12",
    79: "ArrowRight", 80: "ArrowLeft", 81: "ArrowDown", 82: "ArrowUp",
    224: "ControlLeft", 225: "ShiftLeft", 226: "AltLeft"
]

do {
    let explicitRoot = option("--data-dir").map { URL(fileURLWithPath: $0) }
    let paths = try PebbleDataPaths.resolve(explicit: explicitRoot)
    let window = try SDLWindow(title: "Pebble", width: 1440, height: 810)
    let extensions = try SDLWindow.requiredVulkanInstanceExtensions()
    let vulkan = try VulkanContext(validation: CommandLine.arguments.contains("--validation"),
                                    requiredInstanceExtensions: extensions)
    let surface = try window.createVulkanSurface(instance: vulkan.nativeInstance)
    let initialSize = window.pixelSize
    let swapchain = try vulkan.makeSwapchain(surface: surface.raw,
                                             width: initialSize.width, height: initialSize.height)
    let shaderDirectory: URL = {
        if let explicit = option("--shader-dir") ?? ProcessInfo.processInfo.environment["PEBBLE_VULKAN_SHADERS"] {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        let besideExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("shaders", isDirectory: true)
        if FileManager.default.fileExists(atPath: besideExecutable.path) { return besideExecutable }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/vulkan-shaders", isDirectory: true)
    }()
    let initialTarget = RenderTarget(width: initialSize.width, height: initialSize.height)
    let backend = try VulkanRendererBackend(context: vulkan, swapchain: swapchain,
                                            shaderDirectory: shaderDirectory, initialTarget: initialTarget)
    NativeNetTransportFactory.installAsDefault()
    let game = GameCore(services: EngineServices(paths: paths, worldStore: try DirectoryWorldStore(paths: paths)))
    let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let resourcePackURLs: [URL] = {
        if let explicit = option("--resource-pack") { return [URL(fileURLWithPath: explicit)] }
        let candidates = [
            executableDirectory.appendingPathComponent("assets/Faithful 32x - 1.20.1.zip"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("packaging/Faithful 32x - 1.20.1.zip"),
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }()
    let host = try WindowsGameHost(renderer: backend,
                                   resourcePacks: ResourcePackStack(urls: resourcePackURLs),
                                   customSkinURL: paths.skinPNG)
    game.host = host
    if let address = option("--connect") {
        let endpoint: NetEndpoint
        switch NetEndpoint.parse(address) {
        case .success(let parsed): endpoint = parsed
        case .failure(let error):
            throw NSError(domain: "PebbleNet", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid server address \(address): \(error)"])
        }
        let playerName = game.settings.playerName?.isEmpty == false ? game.settings.playerName! : "Player"
        let skin = (try? Data(contentsOf: paths.skinPNG)) ?? Data()
        _ = game.joinLan(netDial(endpoint), name: playerName, skin: skin)
        print("PEBBLE_CONNECTING endpoint=\(endpoint.description) name=\(playerName)")
    } else {
        if let requestedWorld = option("--world"),
           let record = game.listWorlds().first(where: { $0.id == requestedWorld || $0.name == requestedWorld }) {
            game.loadWorld(record.id)
        } else if let seed = option("--seed") {
            game.createWorld(name: "World \(game.listWorlds().count + 1)", seedText: seed, mode: 0, difficulty: 2)
        } else if CommandLine.arguments.contains("--autoload") {
            if let first = game.listWorlds().first { game.loadWorld(first.id) }
            else { game.createWorld(name: "World", seedText: "", mode: 0, difficulty: 2) }
        } else {
            host.openTitleScreen()
        }
        if CommandLine.arguments.contains("--open-to-lan") { _ = game.startLanHost() }
    }
    window.setRelativeMouse(!host.hasScreen())
    if CommandLine.arguments.contains("--fullscreen") { try window.setFullscreen(true) }

    let info = vulkan.info
    print("PEBBLE_WINDOW_READY device=\(info.name) api=\(info.apiVersionString) size=\(window.pixelSize.width)x\(window.pixelSize.height)")
    var running = true
    var controlHeld = false
    var screenshotRequested = option("--screenshot") != nil
    var lastFrame = DispatchTime.now().uptimeNanoseconds
    let startTime = lastFrame
    while running {
        while let event = window.pollEvent() {
            switch event {
            case .quit: running = false
            case .key(let scancode, let pressed, let repeatEvent):
                guard let code = scancodeMap[scancode] else { continue }
                if code == "ControlLeft" { controlHeld = pressed }
                if code == "F11", pressed, !repeatEvent {
                    try window.toggleFullscreen()
                    continue
                }
                if code == "F2", pressed, !repeatEvent {
                    screenshotRequested = true
                    continue
                }
                if code == "Escape", pressed, host.hasScreen() {
                    if host.escapeScreen() {
                        window.setTextInput(false)
                        window.setRelativeMouse(!host.hasScreen())
                    }
                } else if pressed, host.hasScreen() {
                    if host.screenKey(code, game: game) {
                        window.setTextInput(false)
                        window.setRelativeMouse(true)
                    }
                } else if pressed && !repeatEvent {
                    game.keyDown(code, now: Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000,
                                 ctrlOrCmd: controlHeld)
                } else if !pressed {
                    game.keyUp(code)
                }
            case .mouseMotion(let x, let y, let dx, let dy):
                if host.hasScreen() { host.screenMouse(x: x, y: y) }
                else { game.mouseDelta(Double(dx), Double(dy)) }
            case .mouseButton(let button, let pressed):
                let mapped = button == 1 ? 0 : button == 3 ? 2 : 1
                if host.hasScreen() {
                    if pressed { host.screenMouseButton(mapped, game: game) }
                } else if pressed { game.mouseDown(mapped) } else { game.mouseUp(mapped) }
            case .mouseWheel(_, let y):
                if !host.hasScreen(), y != 0 { game.wheelHotbar(y > 0 ? -1 : 1) }
            case .text(let text): host.screenText(text)
            case .focusChanged(let focused):
                if !focused {
                    game.clearInput()
                    controlHeld = false
                    window.setRelativeMouse(false)
                } else if !host.hasScreen() {
                    window.setRelativeMouse(true)
                }
            default: break
            }
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let dtMs = Double(now - lastFrame) / 1_000_000
        lastFrame = now
        let timeSec = Double(now - startTime) / 1_000_000_000
        let partial = game.frame(dtMs: dtMs)
        let size = window.pixelSize
        if size.width > 0 && size.height > 0 {
            let target = RenderTarget(width: size.width, height: size.height)
            let frame = host.buildFrame(game: game, target: target, partial: partial, timeSec: timeSec)
            try backend.render(frame, target: target)
            if screenshotRequested {
                let capture = try backend.captureRGBA8()
                let png = try PNG.encode(PNGImage(width: capture.width, height: capture.height,
                                                  pixels: capture.pixels))
                let output = option("--screenshot").map { URL(fileURLWithPath: $0) }
                    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .appendingPathComponent("Pebble-screenshot.png")
                try png.write(to: output, options: .atomic)
                print("PEBBLE_SCREENSHOT \(output.path)")
                screenshotRequested = false
            }
        }
        if host.hasScreen() {
            window.setRelativeMouse(false)
            window.setTextInput(true)
        }
        if host.exitRequested { running = false }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
    }
    game.saveAndFlush(synchronous: true)
    vulkan.waitUntilIdle()
} catch {
    FileHandle.standardError.write(Data("pebble-win: \(error)\n".utf8))
    exit(1)
}
