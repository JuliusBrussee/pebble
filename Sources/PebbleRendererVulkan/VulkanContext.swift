import Foundation
import CPebbleVulkan

public struct VulkanDeviceInfo: Sendable {
    public let name: String
    public let apiVersion: UInt32
    public let vendorID: UInt32
    public let deviceID: UInt32
    public let graphicsQueueFamily: UInt32
    public let validationEnabled: Bool
    public let validationMessageCount: UInt32
    public let portabilityEnabled: Bool

    public var apiVersionString: String {
        let major = (apiVersion >> 22) & 0x7f
        let minor = (apiVersion >> 12) & 0x3ff
        let patch = apiVersion & 0xfff
        return "\(major).\(minor).\(patch)"
    }
}

public struct VulkanBootstrapError: Error, CustomStringConvertible {
    public let status: Int32
    public let message: String
    public var description: String { "Vulkan bootstrap failed [\(status)]: \(message)" }
}

public final class VulkanContext: @unchecked Sendable {
    private let handle: OpaquePointer
    public let info: VulkanDeviceInfo

    public init(validation: Bool, requiredInstanceExtensions: [String] = []) throws {
        var handle: OpaquePointer?
        let allocated: [UnsafeMutablePointer<CChar>] = requiredInstanceExtensions.map { value in
            let bytes = Array(value.utf8CString)
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            pointer.initialize(from: bytes, count: bytes.count)
            return pointer
        }
        defer { for pointer in allocated { pointer.deallocate() } }
        let pointers = allocated.map { UnsafePointer<CChar>($0) }
        let status = pointers.withUnsafeBufferPointer { buffer in
            pb_vulkan_create_with_extensions(validation ? 1 : 0,
                                              buffer.baseAddress, UInt32(buffer.count), &handle)
        }
        guard status == PB_VULKAN_OK, let handle else {
            throw VulkanBootstrapError(status: status.rawValue, message: String(cString: pb_vulkan_last_error()))
        }
        self.handle = handle
        var raw = PBVulkanInfo()
        raw.struct_size = UInt32(MemoryLayout<PBVulkanInfo>.size)
        let infoStatus = pb_vulkan_get_info(handle, &raw)
        guard infoStatus == PB_VULKAN_OK else {
            pb_vulkan_destroy(handle)
            throw VulkanBootstrapError(status: infoStatus.rawValue, message: String(cString: pb_vulkan_last_error()))
        }
        let name = withUnsafePointer(to: &raw.device_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        info = VulkanDeviceInfo(name: name, apiVersion: raw.api_version,
                                vendorID: raw.vendor_id, deviceID: raw.device_id,
                                graphicsQueueFamily: raw.queue_family,
                                validationEnabled: raw.validation_enabled != 0,
                                validationMessageCount: raw.validation_message_count,
                                portabilityEnabled: raw.portability_enabled != 0)
    }

    deinit { pb_vulkan_destroy(handle) }
    public var nativeInstance: UInt { pb_vulkan_native_instance(handle) }
    public func waitUntilIdle() { pb_vulkan_wait_idle(handle) }

    public func renderClear(width: Int, height: Int,
                            color: SIMD4<Float>) throws -> [UInt8] {
        guard width > 0, height > 0,
              width <= Int(UInt32.max), height <= Int(UInt32.max) else {
            throw VulkanBootstrapError(status: PB_VULKAN_BAD_ARGUMENT.rawValue,
                                       message: "invalid offscreen dimensions")
        }
        let (pixelCount, overflowA) = width.multipliedReportingOverflow(by: height)
        let (byteCount, overflowB) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !overflowA, !overflowB else {
            throw VulkanBootstrapError(status: PB_VULKAN_BAD_ARGUMENT.rawValue,
                                       message: "offscreen dimensions overflow")
        }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBufferPointer {
            pb_vulkan_render_clear(handle, UInt32(width), UInt32(height),
                                   color.x, color.y, color.z, color.w,
                                   $0.baseAddress, $0.count)
        }
        guard status == PB_VULKAN_OK else {
            throw VulkanBootstrapError(status: status.rawValue,
                                       message: String(cString: pb_vulkan_last_error()))
        }
        return bytes
    }

    public func makeSwapchain(surface: UInt64, width: Int, height: Int) throws -> VulkanSwapchain {
        try VulkanSwapchain(context: self, contextHandle: handle, surface: surface,
                            width: width, height: height)
    }

    func makeMesh(vertexBytes: [UInt8], indexBytes: [UInt8], indexStride: UInt32) throws -> VulkanMeshResource {
        try VulkanMeshResource(context: self, contextHandle: handle,
                               vertexBytes: vertexBytes, indexBytes: indexBytes, indexStride: indexStride)
    }

    func makeTextureRGBA8(width: Int, height: Int, layers: Int, bytes: [UInt8]) throws -> VulkanTextureResource {
        try VulkanTextureResource(context: self, contextHandle: handle,
                                  width: width, height: height, layers: layers, bytes: bytes)
    }
}

public enum VulkanPresentResult: Sendable, Equatable { case presented, needsResize }

public final class VulkanSwapchain: @unchecked Sendable {
    private let context: VulkanContext
    private let handle: OpaquePointer
    var nativeHandle: OpaquePointer { handle }

    fileprivate init(context: VulkanContext, contextHandle: OpaquePointer,
                     surface: UInt64, width: Int, height: Int) throws {
        self.context = context
        var handle: OpaquePointer?
        let status = pb_vulkan_swapchain_create(contextHandle, surface, UInt32(width), UInt32(height), &handle)
        guard status == PB_VULKAN_OK, let handle else {
            throw VulkanBootstrapError(status: status.rawValue, message: String(cString: pb_vulkan_last_error()))
        }
        self.handle = handle
    }

    deinit { pb_vulkan_swapchain_destroy(handle) }

    public func resize(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { return }
        let status = pb_vulkan_swapchain_resize(handle, UInt32(width), UInt32(height))
        guard status == PB_VULKAN_OK else {
            throw VulkanBootstrapError(status: status.rawValue, message: String(cString: pb_vulkan_last_error()))
        }
    }

    public func presentClear(_ color: SIMD4<Float>) throws -> VulkanPresentResult {
        let status = pb_vulkan_swapchain_present_clear(handle, color.x, color.y, color.z, color.w)
        if status == PB_VULKAN_OUT_OF_DATE { return .needsResize }
        guard status == PB_VULKAN_OK else {
            throw VulkanBootstrapError(status: status.rawValue, message: String(cString: pb_vulkan_last_error()))
        }
        return .presented
    }
}

final class VulkanMeshResource: @unchecked Sendable {
    private let context: VulkanContext
    private let handle: OpaquePointer
    var nativeHandle: OpaquePointer { handle }

    init(context: VulkanContext, contextHandle: OpaquePointer,
         vertexBytes: [UInt8], indexBytes: [UInt8], indexStride: UInt32) throws {
        self.context = context
        var handle: OpaquePointer?
        let status = vertexBytes.withUnsafeBytes { vertices in
            indexBytes.withUnsafeBytes { indices in
                pb_vulkan_mesh_create(contextHandle,
                                      vertices.bindMemory(to: UInt8.self).baseAddress, vertices.count,
                                      indices.bindMemory(to: UInt8.self).baseAddress, indices.count,
                                      indexStride, &handle)
            }
        }
        guard status == PB_VULKAN_OK, let handle else {
            throw VulkanBootstrapError(status: status.rawValue, message: String(cString: pb_vulkan_last_error()))
        }
        self.handle = handle
    }

    deinit { pb_vulkan_mesh_destroy(handle) }

    func update(vertexBytes: [UInt8], indexBytes: [UInt8], indexStride: UInt32) throws {
        let status = vertexBytes.withUnsafeBytes { vertices in
            indexBytes.withUnsafeBytes { indices in
                pb_vulkan_mesh_update(handle,
                                      vertices.bindMemory(to: UInt8.self).baseAddress, vertices.count,
                                      indices.bindMemory(to: UInt8.self).baseAddress, indices.count,
                                      indexStride)
            }
        }
        guard status == PB_VULKAN_OK else {
            throw VulkanBootstrapError(status: status.rawValue, message: String(cString: pb_vulkan_last_error()))
        }
    }
}

final class VulkanTextureResource: @unchecked Sendable {
    private let context: VulkanContext
    private let handle: OpaquePointer
    var nativeHandle: OpaquePointer { handle }
    let width: Int
    let height: Int
    let layers: Int

    init(context: VulkanContext, contextHandle: OpaquePointer,
         width: Int, height: Int, layers: Int, bytes: [UInt8]) throws {
        self.context = context
        self.width = width
        self.height = height
        self.layers = layers
        var handle: OpaquePointer?
        let status = bytes.withUnsafeBufferPointer {
            pb_vulkan_texture_create_rgba8(contextHandle, UInt32(width), UInt32(height), UInt32(layers),
                                           $0.baseAddress, $0.count, &handle)
        }
        guard status == PB_VULKAN_OK, let handle else {
            throw VulkanBootstrapError(status: status.rawValue, message: String(cString: pb_vulkan_last_error()))
        }
        self.handle = handle
    }

    deinit { pb_vulkan_texture_destroy(handle) }

    func update(bytes: [UInt8]) throws {
        let status = bytes.withUnsafeBufferPointer { pb_vulkan_texture_update_rgba8(handle, $0.baseAddress, $0.count) }
        guard status == PB_VULKAN_OK else {
            throw VulkanBootstrapError(status: status.rawValue, message: String(cString: pb_vulkan_last_error()))
        }
    }
}
