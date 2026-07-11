import Foundation
import PebbleCodecs
import PebbleCore

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

    public func blockAtlas(fallback: BuiltAtlas) -> BuiltAtlas {
        blockAtlasResult(fallback: fallback).atlas
    }

    public func blockAtlasResult(fallback: BuiltAtlas) -> PortableAtlasResult {
        let names = allTileNames()
        guard !packs.isEmpty, fallback.pixels.count == names.count else {
            return PortableAtlasResult(atlas: fallback, animations: [])
        }
        var slices = fallback.pixels
        var animations: [PortableTileAnimation] = []
        for (index, name) in names.enumerated() {
            for candidate in blockTextureCandidates(name) {
                guard let pack = packs.first(where: { $0.file($0.textureRoot + candidate + ".png") != nil }),
                      var image = pack.texture(candidate + ".png") else { continue }
                if image.height > image.width, image.height % image.width == 0 {
                    let frameCount = image.height / image.width
                    var frames: [[UInt8]] = []
                    for frame in 0..<frameCount {
                        let start = frame * image.width * image.width * 4
                        let pixels = Array(image.pixels[start..<(start + image.width * image.width * 4)])
                        var resized = resizeSquare(PNGImage(width: image.width, height: image.width,
                                                            pixels: pixels), size: TILE)
                        if let color = bakedBlockTint[name] { tint(&resized, color: color) }
                        frames.append(resized)
                    }
                    if frames.count > 1 {
                        let timing = animationTiming(pack: pack, path: candidate, frameCount: frames.count)
                        animations.append(PortableTileAnimation(slice: index, frames: frames,
                                                                 order: timing.order, ticks: timing.ticks))
                    }
                    image.pixels = Array(image.pixels.prefix(image.width * image.width * 4))
                    image.height = image.width
                }
                guard image.width == image.height else { continue }
                var pixels = resizeSquare(image, size: TILE)
                if let color = bakedBlockTint[name] { tint(&pixels, color: color) }
                slices[index] = pixels
                break
            }
        }
        return PortableAtlasResult(
            atlas: BuiltAtlas(count: slices.count, pixels: slices, missing: fallback.missing),
            animations: animations)
    }
}

public struct PortableTileAnimation: Sendable {
    public let slice: Int
    public let frames: [[UInt8]]
    public let order: [Int]
    public let ticks: [Int]
}

public struct PortableAtlasResult: Sendable {
    public let atlas: BuiltAtlas
    public let animations: [PortableTileAnimation]
}

private func animationTiming(pack: PortableResourcePack, path: String,
                             frameCount: Int) -> (order: [Int], ticks: [Int]) {
    var frameTime = 1
    var order = Array(0..<frameCount)
    var ticks = [Int](repeating: 1, count: frameCount)
    guard let data = pack.file(pack.textureRoot + path + ".png.mcmeta"),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let animation = root["animation"] as? [String: Any] else { return (order, ticks) }
    frameTime = max(1, animation["frametime"] as? Int ?? 1)
    if let values = animation["frames"] as? [Any] {
        var parsedOrder: [Int] = [], parsedTicks: [Int] = []
        for value in values {
            if let index = value as? Int, index >= 0 && index < frameCount {
                parsedOrder.append(index); parsedTicks.append(frameTime)
            } else if let object = value as? [String: Any], let index = object["index"] as? Int,
                      index >= 0 && index < frameCount {
                parsedOrder.append(index); parsedTicks.append(max(1, object["time"] as? Int ?? frameTime))
            }
        }
        if !parsedOrder.isEmpty { order = parsedOrder; ticks = parsedTicks }
    } else {
        ticks = [Int](repeating: frameTime, count: frameCount)
    }
    return (order, ticks)
}

private let blockNameMap: [String: [String]] = [
    "grass_top": ["block/grass_block_top"], "grass_side": ["block/grass_block_side"],
    "farmland_dry": ["block/farmland"], "farmland_wet": ["block/farmland_moist"],
    "sandstone_side": ["block/sandstone"], "red_sandstone_side": ["block/red_sandstone"],
    "snow_block": ["block/snow"], "frosted_ice": ["block/frosted_ice_0"],
    "dried_kelp_block": ["block/dried_kelp_side"], "magma_block": ["block/magma"],
    "water": ["block/water_still"], "lava": ["block/lava_still"],
    "fire": ["block/fire_0"], "soul_fire": ["block/soul_fire_0"],
    "short_grass": ["block/short_grass", "block/grass"],
    "bamboo": ["block/bamboo_stalk"], "bamboo_sapling": ["block/bamboo_stage0"],
    "big_dripleaf": ["block/big_dripleaf_top"], "small_dripleaf": ["block/small_dripleaf_top"],
    "furnace_front_lit": ["block/furnace_front_on"],
    "blast_furnace_front_lit": ["block/blast_furnace_front_on"],
    "smoker_front_lit": ["block/smoker_front_on"], "observer_back_lit": ["block/observer_back_on"],
    "redstone_dust_line": ["block/redstone_dust_line0"],
    "smoke_particle": ["particle/big_smoke_2", "particle/generic_3"],
    "flame_particle": ["particle/flame"], "heart_particle": ["particle/heart"],
    "crit_particle": ["particle/critical_hit"], "bubble_particle": ["particle/bubble"],
    "note_particle": ["particle/note"], "soul_particle": ["particle/soul_1"],
    "sweep_particle": ["particle/sweep_2"], "snow_particle": ["particle/snowflake"],
    "portal_particle": ["particle/glow"], "slime_particle": ["item/slime_ball"],
]

private let bakedBlockTint: [String: Int] = [
    "birch_leaves": 0x80a755, "spruce_leaves": 0x619961,
    "redstone_dust_dot": 0xff3030, "redstone_dust_line": 0xff3030,
]

private func blockTextureCandidates(_ name: String) -> [String] {
    if let mapped = blockNameMap[name] { return mapped }
    if name.hasPrefix("destroy_"), let stage = Int(name.dropFirst("destroy_".count)) {
        return ["block/destroy_stage_\(stage)"]
    }
    if name.hasPrefix("stem_stage") { return ["block/pumpkin_stem", "block/melon_stem"] }
    if name.hasSuffix("_door") { return ["block/\(name)_bottom"] }
    return ["block/\(name)"]
}

private func resizeSquare(_ image: PNGImage, size: Int) -> [UInt8] {
    if image.width == size && image.height == size { return image.pixels }
    var output = [UInt8](repeating: 0, count: size * size * 4)
    for y in 0..<size {
        let sourceY = y * image.height / size
        for x in 0..<size {
            let sourceX = x * image.width / size
            let source = (sourceY * image.width + sourceX) * 4
            let destination = (y * size + x) * 4
            output[destination] = image.pixels[source]
            output[destination + 1] = image.pixels[source + 1]
            output[destination + 2] = image.pixels[source + 2]
            output[destination + 3] = image.pixels[source + 3]
        }
    }
    return output
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
