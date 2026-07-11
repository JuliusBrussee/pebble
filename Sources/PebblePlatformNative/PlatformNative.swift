// thin portable Swift wrapper over the CPebblePlatform C ABI.
// no Vulkan/SDL/miniaudio/socket/codec logic lives here — just the capability query surface.

import Foundation
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
    public let hasNativeAudio: Bool
}

public enum PebblePlatform {
    /// bytes the header declares for PBPlatformCapabilities: 8 uint32_t fields + reserved[7] uint32_t.
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
            hasCodecs: caps.has_codecs != 0,
            hasNativeAudio: caps.has_native_audio != 0
        )
    }
}

public final class NativeSocket: @unchecked Sendable {
    private let handle: OpaquePointer
    private let stateLock = NSLock()
    private var interrupted = false

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        pb_socket_close(handle)
    }

    public static func connect(host: String, port: UInt16) throws -> NativeSocket {
        var handle: OpaquePointer?
        let status = host.withCString { pb_socket_connect($0, port, &handle) }
        guard status == PB_PLATFORM_OK, let handle else {
            throw PebblePlatformError.from(status, PebblePlatform.lastError())
        }
        return NativeSocket(handle: handle)
    }

    public static func listen(port: UInt16, backlog: Int32 = 64) throws -> (socket: NativeSocket, port: UInt16) {
        var handle: OpaquePointer?
        var boundPort: UInt16 = 0
        let status = pb_socket_listen(port, backlog, &handle, &boundPort)
        guard status == PB_PLATFORM_OK, let handle else {
            throw PebblePlatformError.from(status, PebblePlatform.lastError())
        }
        return (NativeSocket(handle: handle), boundPort)
    }

    public func accept() throws -> NativeSocket {
        var accepted: OpaquePointer?
        let status = pb_socket_accept(handle, &accepted)
        guard status == PB_PLATFORM_OK, let accepted else {
            throw PebblePlatformError.from(status, PebblePlatform.lastError())
        }
        return NativeSocket(handle: accepted)
    }

    public func send(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let sent: Int = try data.withUnsafeBytes { raw in
                var count = 0
                let base = raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset)
                let status = pb_socket_send(handle, base, data.count - offset, &count)
                guard status == PB_PLATFORM_OK else {
                    throw PebblePlatformError.from(status, PebblePlatform.lastError())
                }
                return count
            }
            guard sent > 0 else { throw PebblePlatformError.unavailable("socket closed during send") }
            offset += sent
        }
    }

    public func receive(maxBytes: Int = 64 * 1024) throws -> Data? {
        precondition(maxBytes > 0)
        var bytes = [UInt8](repeating: 0, count: maxBytes)
        var received = 0
        let status = bytes.withUnsafeMutableBufferPointer {
            pb_socket_receive(handle, $0.baseAddress, $0.count, &received)
        }
        guard status == PB_PLATFORM_OK else {
            throw PebblePlatformError.from(status, PebblePlatform.lastError())
        }
        return received == 0 ? nil : Data(bytes.prefix(received))
    }

    public func shutdownWrite() throws {
        let status = pb_socket_shutdown(handle, PB_SOCKET_SHUTDOWN_WRITE)
        guard status == PB_PLATFORM_OK else {
            throw PebblePlatformError.from(status, PebblePlatform.lastError())
        }
    }

    public func interrupt() {
        stateLock.lock()
        guard !interrupted else { stateLock.unlock(); return }
        interrupted = true
        stateLock.unlock()
        pb_socket_interrupt(handle)
    }
}

private final class AudioRenderBox {
    let render: (UnsafeMutableBufferPointer<Float>, Int, Int) -> Void
    init(render: @escaping (UnsafeMutableBufferPointer<Float>, Int, Int) -> Void) { self.render = render }
}

private func nativeAudioRender(_ samples: UnsafeMutablePointer<Float>?,
                               _ frameCount: UInt32,
                               _ channelCount: UInt32,
                               _ userData: UnsafeMutableRawPointer?) {
    guard let samples, let userData else { return }
    let box = Unmanaged<AudioRenderBox>.fromOpaque(userData).takeUnretainedValue()
    box.render(UnsafeMutableBufferPointer(start: samples,
                                          count: Int(frameCount) * Int(channelCount)),
               Int(frameCount), Int(channelCount))
}

public final class NativeAudioDevice: @unchecked Sendable {
    private let handle: OpaquePointer
    private let renderBox: Unmanaged<AudioRenderBox>
    private var started = false

    public init(sampleRate: UInt32 = 48_000,
                channels: UInt32 = 2,
                periodFrames: UInt32 = 512,
                render: @escaping (UnsafeMutableBufferPointer<Float>, Int, Int) -> Void) throws {
        let box = Unmanaged.passRetained(AudioRenderBox(render: render))
        var handle: OpaquePointer?
        let status = pb_audio_create(sampleRate, channels, periodFrames,
                                     nativeAudioRender, box.toOpaque(), &handle)
        guard status == PB_PLATFORM_OK, let handle else {
            box.release()
            throw PebblePlatformError.from(status, PebblePlatform.lastError())
        }
        self.handle = handle
        renderBox = box
    }

    deinit {
        pb_audio_destroy(handle)
        renderBox.release()
    }

    public func start() throws {
        if started { return }
        let status = pb_audio_start(handle)
        guard status == PB_PLATFORM_OK else {
            throw PebblePlatformError.from(status, PebblePlatform.lastError())
        }
        started = true
    }

    public func stop() {
        if !started { return }
        _ = pb_audio_stop(handle)
        started = false
    }

    public var underrunCount: UInt64 { pb_audio_underrun_count(handle) }
}
