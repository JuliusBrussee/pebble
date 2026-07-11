import Foundation
import CPebbleSDL

public struct SDLWindowError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SDL window error [\(code)]: \(message)" }
}

public enum WindowEvent: Sendable {
    case quit
    case resized(width: Int, height: Int)
    case key(scancode: Int, pressed: Bool, repeatEvent: Bool)
    case mouseMotion(dx: Float, dy: Float)
    case mouseButton(button: Int, pressed: Bool)
    case mouseWheel(x: Float, y: Float)
    case text(String)
}

public final class VulkanSurface: @unchecked Sendable {
    public let raw: UInt64
    private let instance: UInt

    fileprivate init(raw: UInt64, instance: UInt) {
        self.raw = raw
        self.instance = instance
    }

    deinit { pb_window_destroy_vulkan_surface(instance, raw) }
}

public final class SDLWindow: @unchecked Sendable {
    private let handle: OpaquePointer

    public init(title: String, width: Int, height: Int) throws {
        var handle: OpaquePointer?
        let result = title.withCString { pb_window_create($0, Int32(width), Int32(height), &handle) }
        guard result == 0, let handle else {
            throw SDLWindowError(code: result, message: String(cString: pb_window_last_error()))
        }
        self.handle = handle
    }

    deinit { pb_window_destroy(handle) }

    public static func requiredVulkanInstanceExtensions() throws -> [String] {
        var count: UInt32 = 0
        guard let extensions = pb_window_vulkan_extensions(&count) else {
            throw SDLWindowError(code: -1, message: String(cString: pb_window_last_error()))
        }
        return (0..<Int(count)).compactMap { index in
            extensions[index].map { String(cString: $0) }
        }
    }

    public func createVulkanSurface(instance: UInt) throws -> VulkanSurface {
        var surface: UInt64 = 0
        let result = pb_window_create_vulkan_surface(handle, instance, &surface)
        guard result == 0, surface != 0 else {
            throw SDLWindowError(code: result, message: String(cString: pb_window_last_error()))
        }
        return VulkanSurface(raw: surface, instance: instance)
    }

    public var pixelSize: (width: Int, height: Int) {
        var width: Int32 = 0, height: Int32 = 0
        pb_window_size_pixels(handle, &width, &height)
        return (Int(width), Int(height))
    }

    public func setRelativeMouse(_ enabled: Bool) {
        pb_window_set_relative_mouse(handle, enabled ? 1 : 0)
    }

    public func pollEvent() -> WindowEvent? {
        while true {
            var event = PBWindowEvent()
            event.struct_size = UInt32(MemoryLayout<PBWindowEvent>.size)
            let result = pb_window_poll_event(handle, &event)
            if result <= 0 { return nil }
            switch event.type {
            case PB_WINDOW_EVENT_QUIT: return .quit
            case PB_WINDOW_EVENT_RESIZED: return .resized(width: Int(event.a), height: Int(event.b))
            case PB_WINDOW_EVENT_KEY_DOWN: return .key(scancode: Int(event.a), pressed: true, repeatEvent: event.b != 0)
            case PB_WINDOW_EVENT_KEY_UP: return .key(scancode: Int(event.a), pressed: false, repeatEvent: false)
            case PB_WINDOW_EVENT_MOUSE_MOTION: return .mouseMotion(dx: event.x, dy: event.y)
            case PB_WINDOW_EVENT_MOUSE_BUTTON_DOWN: return .mouseButton(button: Int(event.a), pressed: true)
            case PB_WINDOW_EVENT_MOUSE_BUTTON_UP: return .mouseButton(button: Int(event.a), pressed: false)
            case PB_WINDOW_EVENT_MOUSE_WHEEL: return .mouseWheel(x: event.x, y: event.y)
            case PB_WINDOW_EVENT_TEXT:
                let text = withUnsafePointer(to: &event.text) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
                }
                return .text(text)
            default: continue
            }
        }
    }
}
