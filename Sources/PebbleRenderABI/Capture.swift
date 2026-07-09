// The screenshot/readback contract — derived from the ONLY frame-capture
// path in the current Metal renderer: Sources/Pebble/PhotoBooth.swift calls
// WorldRenderer.requestCapture(path:), which is serviced by
// WorldRenderer.encodeCapture(_:from:) at Sources/Pebble/WorldRenderer.swift:
// 508-537.
//
// encodeCapture blits the composited drawable texture (colorPixelFormat set
// to `.bgra8Unorm` at Sources/Pebble/main.swift:418; the compositePipeline
// that renders into it also targets `.bgra8Unorm`, the `pipe()` helper's
// default — Sources/Pebble/WorldRenderer.swift:309,391) into an
// `MTLBuffer` with `destinationBytesPerRow: w * 4` (WorldRenderer.swift:514,
// 521) — i.e. tightly packed, no row-alignment padding beyond 4 bytes/pixel.
//
// That buffer is handed straight to `CGImage` with
// `CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue`
// (WorldRenderer.swift:528-529). `.noneSkipFirst` means the image has NO
// alpha channel — the 4th byte of every BGRA8 pixel is treated as unused
// padding and ignored, not as straight or premultiplied alpha. This is safe
// because composite_fs always writes alpha = 1.0 (Shaders.swift:749,
// `return float4(c, 1.0);`) — every capture is fully opaque by construction,
// so the code never needed to decide between straight/premultiplied.
//
// No flip is applied anywhere in the capture path, so the buffer's row 0 is
// whatever Metal's blit-from-texture wrote as row 0 of the source texture —
// the top row of the rendered image, matching normal top-down raster/PNG
// order.

public enum CapturePixelFormat: Hashable, Sendable {
    /// 4 bytes/pixel, in-memory byte order B, G, R, X (X = unused/ignored,
    /// not blended) — the readback of a Metal `.bgra8Unorm` drawable with its
    /// alpha byte discarded. See the file-level doc comment above.
    case bgra8UnormOpaque
}

public enum CaptureOrigin: Hashable, Sendable {
    /// row 0 of `pixels` is the top row of the image.
    case topLeft
}

public struct CaptureImage: Sendable {
    public var width: Int
    public var height: Int
    /// always `width * 4` for the current capture path (tightly packed, no
    /// row-alignment padding) — kept as an explicit field rather than always
    /// recomputed because a Vulkan readback may have to honor
    /// VkPhysicalDeviceLimits::optimalBufferCopyRowPitchAlignment and pad
    /// rows, which this ABI must be able to represent even though today's
    /// Metal path never does.
    public var bytesPerRow: Int
    public var format: CapturePixelFormat
    public var origin: CaptureOrigin
    public var pixels: [UInt8]

    public init(width: Int, height: Int, bytesPerRow: Int, format: CapturePixelFormat,
                origin: CaptureOrigin, pixels: [UInt8]) {
        self.width = width; self.height = height; self.bytesPerRow = bytesPerRow
        self.format = format; self.origin = origin; self.pixels = pixels
    }
}
