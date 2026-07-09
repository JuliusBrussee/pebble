// thin portable Swift wrapper over the CPebblePlatform C ABI.
// no Vulkan/SDL/miniaudio/socket/codec logic lives here — just the capability query surface.

import CPebblePlatform

/// mirrors PBPlatformStatus (see CPebblePlatform.h) as a Swift error.
public enum PebblePlatformError: Error, CustomStringConvertible {
    case badArgument(String)
    case badSize(String)
    case unavailable(String)
    case internalError(String)
    case unknownStatus(Int32, String)

    public var description: String {
        switch self {
        case .badArgument(let msg): return "PB_PLATFORM_BAD_ARGUMENT: \(msg)"
        case .badSize(let msg): return "PB_PLATFORM_BAD_SIZE: \(msg)"
        case .unavailable(let msg): return "PB_PLATFORM_UNAVAILABLE: \(msg)"
        case .internalError(let msg): return "PB_PLATFORM_INTERNAL: \(msg)"
        case .unknownStatus(let code, let msg): return "unknown PBPlatformStatus \(code): \(msg)"
        }
    }

    fileprivate static func from(_ status: PBPlatformStatus, _ message: String) -> PebblePlatformError {
        switch status {
        case PB_PLATFORM_BAD_ARGUMENT: return .badArgument(message)
        case PB_PLATFORM_BAD_SIZE: return .badSize(message)
        case PB_PLATFORM_UNAVAILABLE: return .unavailable(message)
        case PB_PLATFORM_INTERNAL: return .internalError(message)
        default: return .unknownStatus(status.rawValue, message)
        }
    }
}

/// Swift-native view of PBPlatformCapabilities — all flags false until a lane wires a real backend.
public struct PebblePlatformCapabilities {
    public let abiVersion: UInt32
    public let hasVulkan: Bool
    public let hasSDL: Bool
    public let hasMiniaudio: Bool
    public let hasSockets: Bool
    public let hasCodecs: Bool
}

public enum PebblePlatform {
    /// bytes the header declares for PBPlatformCapabilities: 7 uint32_t fields + reserved[8] uint32_t.
    private static let declaredCapabilitiesSize = 4 * (7 + 8)

    /// struct_size self-check: if the Swift-imported layout of PBPlatformCapabilities ever
    /// drifts from what CPebblePlatform.h declares (padding, reordering, ABI bump), every
    /// capability query below is unsafe to trust.
    public static func layoutMatchesHeader() -> Bool {
        MemoryLayout<PBPlatformCapabilities>.size == declaredCapabilitiesSize
    }

    public static var abiVersion: UInt32 {
        pb_platform_abi_version()
    }

    public static func lastError() -> String {
        String(cString: pb_platform_last_error())
    }

    public static func capabilities() throws -> PebblePlatformCapabilities {
        // Swift can't statically assert an imported C struct's layout against the header
        // at compile time, so this is the load-bearing equivalent: any drift here means
        // the rest of this function is reading/writing the wrong bytes and must not proceed.
        precondition(
            layoutMatchesHeader(),
            "PBPlatformCapabilities layout drift: Swift size \(MemoryLayout<PBPlatformCapabilities>.size) != header size \(declaredCapabilitiesSize)"
        )
        var caps = PBPlatformCapabilities()
        caps.struct_size = UInt32(MemoryLayout<PBPlatformCapabilities>.size)
        let status = pb_platform_get_capabilities(&caps)
        guard status == PB_PLATFORM_OK else {
            throw PebblePlatformError.from(status, lastError())
        }
        return PebblePlatformCapabilities(
            abiVersion: caps.abi_version,
            hasVulkan: caps.has_vulkan != 0,
            hasSDL: caps.has_sdl != 0,
            hasMiniaudio: caps.has_miniaudio != 0,
            hasSockets: caps.has_sockets != 0,
            hasCodecs: caps.has_codecs != 0
        )
    }
}
