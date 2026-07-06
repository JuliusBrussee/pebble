// Skins — custom player skins. A skin is a standard Minecraft 64×64 PNG
// (the unfolded player layout); the player's copy lives at
// ~/Library/Application Support/Pebble/skin.png and EntityRendererM picks it
// up when it builds the "player" model. Deleting the file restores steve.

import AppKit
import Foundation
import ImageIO
import PebbleCore
import UniformTypeIdentifiers

/// the one custom-skin slot — file present = skin active
var customSkinURL: URL { vcSupportDir().appendingPathComponent("skin.png") }

/// decoded + flattened custom skin; nil when absent or not a square 64-multiple,
/// which sends the renderer down the normal pack/procedural steve path
func customPlayerSkin() -> RGBAImage? {
    guard let d = try? Data(contentsOf: customSkinURL), var img = decodePNG(d),
          img.width == img.height, img.width >= 64, img.width % 64 == 0 else { return nil }
    flattenSkinOverlay(&img)
    return img
}

/// modern skins carry a second layer (hat/jacket/sleeves/pants) meant for a
/// slightly larger shell around each part; the player model has no shell
/// boxes, so bake the overlay onto the base layer instead. the model mirrors
/// the right arm/leg onto the left, so only the right-side overlays apply.
func flattenSkinOverlay(_ img: inout RGBAImage) {
    let s = img.width / 64
    func blend(_ sx: Int, _ sy: Int, _ w: Int, _ h: Int, _ dx: Int, _ dy: Int) {
        for py in 0..<(h * s) {
            for px in 0..<(w * s) {
                let si = ((sy * s + py) * img.width + sx * s + px) * 4
                let di = ((dy * s + py) * img.width + dx * s + px) * 4
                let a = Int(img.pixels[si + 3])
                if a == 0 { continue }
                for c in 0..<3 {
                    let o = Int(img.pixels[si + c]), b = Int(img.pixels[di + c])
                    img.pixels[di + c] = UInt8((o * a + b * (255 - a)) / 255)
                }
                img.pixels[di + 3] = 255
            }
        }
    }
    blend(32, 0, 32, 16, 0, 0)      // hat → head
    blend(16, 32, 24, 16, 16, 16)   // jacket → body
    blend(40, 32, 16, 16, 40, 16)   // right sleeve → arm
    blend(0, 32, 16, 16, 0, 16)     // right pants → leg
}

/// straight-RGBA → PNG bytes (template export of the procedural skin)
func encodePNG(_ img: RGBAImage) -> Data? {
    guard let provider = CGDataProvider(data: Data(img.pixels) as CFData),
          let cg = CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: img.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue
                               | CGBitmapInfo.byteOrder32Big.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false,
                           intent: .defaultIntent) else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(dest, cg, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

/// PNG bytes of whatever the player currently wears, for drawing a new skin
/// on top of: the custom skin, else the pack steve, else the procedural paint
func currentSkinTemplateData() -> Data? {
    if let d = try? Data(contentsOf: customSkinURL) { return d }
    for p in ACTIVE_PACKS {
        if let d = p.file(p.texRoot + "entity/player/wide/steve.png") { return d }
    }
    let g = buildEntityGeometry("player")
    return encodePNG(RGBAImage(width: g.skin.w, height: g.skin.h, pixels: g.skin.data))
}

// =============================================================================
final class SkinsScreen: Screen {
    var status = ""
    var statusColor = "#A0FFA0"
    private var statusY = 0.0

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        buttons = []
        let cx = (ui.width / 2).rounded(.down)
        var y = (ui.height / 4).rounded(.down) + 24
        buttons.append(Button(cx - 100, y, 200, 20, "Choose Skin File...", { [weak self, weak ui, weak game] in
            guard let self, let ui, let game else { return }
            self.chooseSkin(ui, game)
        }))
        y += 24
        buttons.append(Button(cx - 100, y, 200, 20, "Save Skin To Draw On...", { [weak self] in
            self?.exportTemplate()
        }))
        y += 24
        let def = Button(cx - 100, y, 200, 20, "Back To Default Skin", { [weak self, weak ui, weak game] in
            guard let self, let ui, let game else { return }
            try? FileManager.default.removeItem(at: customSkinURL)
            gAppDelegate?.renderer.entityRenderer.resetSkins()
            self.status = "Default skin is back."
            self.statusColor = "#A0FFA0"
            self.initScreen(ui, game)
        })
        def.enabled = FileManager.default.fileExists(atPath: customSkinURL.path)
        buttons.append(def)
        y += 24
        statusY = y + 4
        buttons.append(Button(cx - 100, y + 20, 200, 20, "Done", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.closeTop(game)
        }))
    }

    private func chooseSkin(_ ui: UIManager, _ game: GameCore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.message = "Pick a Minecraft skin — a square 64×64 PNG"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        statusColor = "#FF7070"
        guard let d = try? Data(contentsOf: url), let img = decodePNG(d) else {
            status = "Couldn't read that file as a PNG image."
            return
        }
        if img.width == 64 && img.height == 32 {
            status = "That's the old 64x32 skin format - resave it as 64x64."
        } else if img.width != img.height || img.width < 64 || img.width % 64 != 0 {
            status = "Skins must be square 64x64 pixels - that one is \(img.width)x\(img.height)."
        } else {
            try? d.write(to: customSkinURL, options: .atomic)
            gAppDelegate?.renderer.entityRenderer.resetSkins()
            status = "Skin applied! See it in your world with F5 (third person)."
            statusColor = "#A0FFA0"
            initScreen(ui, game)
        }
    }

    private func exportTemplate() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "my-skin.png"
        panel.message = "Save the current skin, then open it in a paint app and draw"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let d = currentSkinTemplateData() {
            try? d.write(to: url)
            status = "Saved! Draw on it, then use Choose Skin File..."
            statusColor = "#A0FFA0"
        } else {
            status = "Couldn't save the skin template."
            statusColor = "#FF7070"
        }
    }

    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        if game.hasWorld() { ui.drawDarkBg(0.65) } else { ui.drawDirtBg() }
        let cx = ui.width / 2
        ui.cv.drawTextCentered("Skins", cx, 6, 1)
        let top = (ui.height / 4).rounded(.down) + 24
        ui.cv.drawTextCentered("A skin is a 64x64 PNG - the player, unfolded flat.", cx, top - 28, 1, "#A0A0A0")
        ui.cv.drawTextCentered("Every pixel has its own spot on the body.", cx, top - 16, 1, "#A0A0A0")
        if !status.isEmpty { ui.cv.drawTextCentered(status, cx, statusY, 1, statusColor) }
        ui.drawButtons(self)
    }
}
