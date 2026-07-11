import Foundation
import PebbleCodecs
import PebbleRendererVulkan

let arguments = Set(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    pebvk — Pebble headless Vulkan renderer

      pebvk [--validation|--no-validation] [--info-json <path>]
            [--output <png>] [--width <px>] [--height <px>]
    """)
    exit(0)
}

let validation = !arguments.contains("--no-validation")
do {
    let context = try VulkanContext(validation: validation)
    let info = context.info
    print("VULKAN_READY device=\(info.name) api=\(info.apiVersionString) queue=\(info.graphicsQueueFamily) validation=\(info.validationEnabled ? "on" : "off") validation_messages=\(info.validationMessageCount) portability=\(info.portabilityEnabled ? "on" : "off")")
    if let index = CommandLine.arguments.firstIndex(of: "--info-json"), index + 1 < CommandLine.arguments.count {
        let object: [String: Any] = [
            "device": info.name,
            "apiVersion": info.apiVersionString,
            "vendorID": info.vendorID,
            "deviceID": info.deviceID,
            "graphicsQueueFamily": info.graphicsQueueFamily,
            "validationEnabled": info.validationEnabled,
            "validationMessageCount": info.validationMessageCount,
            "portabilityEnabled": info.portabilityEnabled,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
    }
    if let index = CommandLine.arguments.firstIndex(of: "--output"), index + 1 < CommandLine.arguments.count {
        func integerOption(_ name: String, fallback: Int) -> Int {
            guard let option = CommandLine.arguments.firstIndex(of: name), option + 1 < CommandLine.arguments.count else { return fallback }
            return Int(CommandLine.arguments[option + 1]) ?? fallback
        }
        let width = integerOption("--width", fallback: 640)
        let height = integerOption("--height", fallback: 360)
        let pixels = try context.renderClear(width: width, height: height,
                                             color: SIMD4<Float>(0.035, 0.055, 0.09, 1))
        let png = try PNG.encode(PNGImage(width: width, height: height, pixels: pixels))
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
        print("VULKAN_CAPTURE path=\(CommandLine.arguments[index + 1]) size=\(width)x\(height)")
    }
    context.waitUntilIdle()
} catch {
    FileHandle.standardError.write(Data("pebvk: \(error)\n".utf8))
    exit(1)
}
