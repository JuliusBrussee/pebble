public enum RendererSelection: String, Sendable {
    case auto
    case metal
    case vulkan

    public static func parse(arguments: [String], environment: [String: String]) -> RendererSelection {
        if let index = arguments.firstIndex(of: "--renderer"), index + 1 < arguments.count,
           let value = RendererSelection(rawValue: arguments[index + 1].lowercased()) {
            return value
        }
        if let raw = environment["PEBBLE_RENDERER"],
           let value = RendererSelection(rawValue: raw.lowercased()) {
            return value
        }
        return .auto
    }
}

public enum RendererAvailability {
    public static func resolve(_ requested: RendererSelection,
                               metalAvailable: Bool,
                               vulkanAvailable: Bool) throws -> RendererSelection {
        switch requested {
        case .auto:
            if metalAvailable { return .metal }
            if vulkanAvailable { return .vulkan }
        case .metal:
            if metalAvailable { return .metal }
        case .vulkan:
            if vulkanAvailable { return .vulkan }
        }
        throw RendererBackendError.unavailable("renderer \(requested.rawValue) is unavailable on this system")
    }
}
