import Foundation
import PebbleCodecs

public final class PortableResourcePack: @unchecked Sendable {
    private let reader: ZipReader
    private let paths: [String: String]
    public let textureRoot: String

    public init(url: URL) throws {
        let reader = try ZipReader(Data(contentsOf: url, options: .mappedIfSafe))
        self.reader = reader
        var paths: [String: String] = [:]
        for name in reader.entries.keys { paths[name.lowercased()] = name }
        self.paths = paths
        var root = "assets/minecraft/textures/"
        for path in paths.keys {
            guard let assets = path.range(of: "assets/") else { continue }
            let suffix = path[assets.upperBound...]
            guard let textures = suffix.range(of: "/textures/") else { continue }
            root = "assets/\(suffix[..<textures.lowerBound])/textures/"
            break
        }
        textureRoot = root
    }

    public func file(_ relativePath: String) -> Data? {
        let direct = relativePath.lowercased()
        if let exact = paths[direct] { return try? reader.extract(exact) }
        if let meta = paths.keys.first(where: { $0.hasSuffix("/pack.mcmeta") }),
           let slash = meta.lastIndex(of: "/") {
            let prefixed = String(meta[...slash]) + direct
            if let exact = paths[prefixed] { return try? reader.extract(exact) }
        }
        return nil
    }

    public func texture(_ relativePath: String) -> PNGImage? {
        guard let data = file(textureRoot + relativePath) else { return nil }
        return try? PNG.decode(data, maxPixelBytes: 4096 * 8192 * 4)
    }
}

public final class ResourcePackStack: @unchecked Sendable {
    public let packs: [PortableResourcePack]

    public init(urls: [URL]) {
        packs = urls.compactMap { try? PortableResourcePack(url: $0) }
    }

    public func entityImage(_ relativePaths: [String], stack: Bool = false,
                            tints: [Int] = []) -> PNGImage? {
        guard !relativePaths.isEmpty else { return nil }
        func load(_ path: String) -> PNGImage? {
            guard var image = packs.lazy.compactMap({ $0.texture(path) }).first else { return nil }
            if let index = relativePaths.firstIndex(of: path), index < tints.count,
               tints[index] != 0xffffff {
                tint(&image.pixels, color: tints[index])
            }
            return image
        }
        guard var base = load(relativePaths[0]) else { return nil }
        if stack {
            for path in relativePaths.dropFirst() {
                guard let next = load(path), next.width == base.width else { return nil }
                base = PNGImage(width: base.width, height: base.height + next.height,
                                pixels: base.pixels + next.pixels)
            }
            return base
        }
        for path in relativePaths.dropFirst() {
            guard let overlay = load(path), overlay.width == base.width,
                  overlay.height == base.height else { continue }
            alphaComposite(&base.pixels, overlay.pixels)
        }
        return base
    }

    public func playerSkin(customURL: URL?) -> PNGImage? {
        if let customURL, let data = try? Data(contentsOf: customURL),
           var image = try? PNG.decode(data), image.width == image.height,
           image.width >= 64, image.width % 64 == 0 {
            flattenPlayerOverlay(&image)
            return image
        }
        return entityImage(["entity/player/wide/steve.png"])
            ?? entityImage(["entity/steve.png"])
    }
}

private func tint(_ pixels: inout [UInt8], color: Int) {
    let red = (color >> 16) & 255, green = (color >> 8) & 255, blue = color & 255
    for index in stride(from: 0, to: pixels.count, by: 4) {
        pixels[index] = UInt8(Int(pixels[index]) * red / 255)
        pixels[index + 1] = UInt8(Int(pixels[index + 1]) * green / 255)
        pixels[index + 2] = UInt8(Int(pixels[index + 2]) * blue / 255)
    }
}

private func alphaComposite(_ base: inout [UInt8], _ overlay: [UInt8]) {
    guard base.count == overlay.count else { return }
    for index in stride(from: 0, to: base.count, by: 4) {
        let alpha = Int(overlay[index + 3])
        if alpha == 0 { continue }
        for component in 0..<3 {
            base[index + component] = UInt8((Int(overlay[index + component]) * alpha +
                                             Int(base[index + component]) * (255 - alpha)) / 255)
        }
        base[index + 3] = 255
    }
}

private func flattenPlayerOverlay(_ image: inout PNGImage) {
    let scale = image.width / 64
    func blend(_ sx: Int, _ sy: Int, _ width: Int, _ height: Int, _ dx: Int, _ dy: Int) {
        for y in 0..<(height * scale) {
            for x in 0..<(width * scale) {
                let source = ((sy * scale + y) * image.width + sx * scale + x) * 4
                let destination = ((dy * scale + y) * image.width + dx * scale + x) * 4
                let alpha = Int(image.pixels[source + 3])
                if alpha == 0 { continue }
                for component in 0..<3 {
                    image.pixels[destination + component] = UInt8(
                        (Int(image.pixels[source + component]) * alpha +
                         Int(image.pixels[destination + component]) * (255 - alpha)) / 255)
                }
                image.pixels[destination + 3] = 255
            }
        }
    }
    blend(32, 0, 32, 16, 0, 0)
    blend(16, 32, 24, 16, 16, 16)
    blend(40, 32, 16, 16, 40, 16)
    blend(0, 32, 16, 16, 0, 16)
}
