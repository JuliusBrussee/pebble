// Gear rendering — worn armor overlays, held items and shields on player
// models (third person + other players in multiplayer). Armor pieces are
// separate biped-part models posed by the same name-based animator as the
// body, so they follow every walk/swing/sneak motion for free. Held items
// are extruded 16×16 icon sprites (one tiny cube per opaque pixel face)
// attached to the posed arm matrices. Nothing here touches the frozen model
// registry: gear geometry is built through buildEntityGeometry(from:).

import Foundation
import Metal
import simd
import PebbleCore

extension EntityRendererM {
    // =========================================================================
    // shared: EntityGeometry + explicit pixels → ModelGPU
    // =========================================================================
    private func makeGPU(_ built: EntityGeometry, _ pixels: [UInt8], _ w: Int, _ h: Int) -> ModelGPU? {
        guard !built.verts.isEmpty else { return nil }
        let vb = built.verts.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max(1, $0.count)) }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                          width: w, height: h, mipmapped: false)
        td.usage = .shaderRead
        guard let vb, let tex = device.makeTexture(descriptor: td) else { return nil }
        pixels.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: w * 4)
        }
        return ModelGPU(vb: vb, count: built.vertexCount, texture: tex, model: built.model)
    }

    // =========================================================================
    // armor overlays
    // =========================================================================
    /// vanilla armor texture material for a worn stack ("golden_helmet" → "gold")
    static func armorMaterial(_ s: ItemStack) -> String? {
        let name = itemDef(s.id).name
        guard name.hasSuffix("_helmet") || name.hasSuffix("_chestplate")
            || name.hasSuffix("_leggings") || name.hasSuffix("_boots") else { return nil }
        let mat = String(name.split(separator: "_").first ?? "")
        return mat == "golden" ? "gold" : mat
    }

    private static let armorColors: [String: Int] = [
        "leather": 0x8a5a33, "chainmail": 0x9a9a9a, "iron": 0xd8d8d8,
        "gold": 0xecc540, "diamond": 0x4dede0, "netherite": 0x443c3f, "turtle": 0x3aa746,
    ]

    /// the overlay rig for one armor slot — part names match the biped so the
    /// animator poses them exactly like the body underneath
    private func armorModel(_ piece: Int, _ mat: String) -> MobModel {
        let color = Self.armorColors[mat] ?? 0x9a9a9a
        func P(_ name: String, _ pivot: (Double, Double, Double), _ boxes: ModelBox...) -> ModelPart {
            ModelPart(name: name, pivot: pivot, boxes: boxes)
        }
        switch piece {
        case 0: // helmet
            return MobModel(texW: 64, texH: 32, parts: [
                P("head", (0, 24, 0), ModelBox(-4, 0, -4, 8, 8, 8, 0, 0, 0.75)),
            ], anim: "biped", scale: 1, paint: { s in s.box(0, 0, 8, 8, 8, color, 0.06) })
        case 1: // chestplate + shoulders
            return MobModel(texW: 64, texH: 32, parts: [
                P("body", (0, 24, 0), ModelBox(-4, -12, -2, 8, 12, 4, 16, 16, 0.51)),
                P("armR", (-5, 22, 0), ModelBox(-3, -10, -2, 4, 12, 4, 40, 16, 0.6)),
                P("armL", (5, 22, 0), ModelBox(-1, -10, -2, 4, 12, 4, 40, 16, 0.6)),
            ], anim: "biped", scale: 1, paint: { s in
                s.box(16, 16, 8, 12, 4, color, 0.06)
                s.box(40, 16, 4, 12, 4, color, 0.06)
            })
        case 2: // leggings (vanilla layer_2)
            return MobModel(texW: 64, texH: 32, parts: [
                P("body", (0, 24, 0), ModelBox(-4, -12, -2, 8, 12, 4, 16, 16, 0.26)),
                P("legR", (-2, 12, 0), ModelBox(-2, -12, -2, 4, 12, 4, 0, 16, 0.26)),
                P("legL", (2, 12, 0), ModelBox(-2, -12, -2, 4, 12, 4, 0, 16, 0.26)),
            ], anim: "biped", scale: 1, paint: { s in
                s.box(16, 16, 8, 12, 4, color, 0.06)
                s.box(0, 16, 4, 12, 4, color, 0.06)
            })
        default: // boots
            return MobModel(texW: 64, texH: 32, parts: [
                P("legR", (-2, 12, 0), ModelBox(-2, -12, -2, 4, 12, 4, 0, 16, 0.76)),
                P("legL", (2, 12, 0), ModelBox(-2, -12, -2, 4, 12, 4, 0, 16, 0.76)),
            ], anim: "biped", scale: 1, paint: { s in s.box(0, 16, 4, 12, 4, color, 0.06) })
        }
    }

    private func armorGeom(_ piece: Int, _ mat: String) -> ModelGPU? {
        let key = "armor:\(piece):\(mat)"
        if let g = gearGeoms[key] { return g }
        let model = armorModel(piece, mat)
        let built = buildEntityGeometry(from: model, skinName: key)
        // vanilla armor sheets are 64×32; leather is grayscale + tinted, with
        // an untinted overlay on top
        let layer = piece == 2 ? "2" : "1"
        var rels = ["models/armor/\(mat)_layer_\(layer).png"]
        var tints: [Int] = []
        if mat == "leather" {
            rels.append("models/armor/leather_layer_\(layer)_overlay.png")
            tints = [0x8a5a33, 0xFFFFFF]
        }
        var pixels = built.skin.data
        var w = built.skin.w, h = built.skin.h
        if let img = packEntityImage(rels, tints: tints), img.width * 32 == img.height * 64 {
            pixels = img.pixels
            w = img.width
            h = img.height
        }
        guard let g = makeGPU(built, pixels, w, h) else { return nil }
        gearGeoms[key] = g
        return g
    }

    // =========================================================================
    // held items — extruded icon sprites
    // =========================================================================
    /// one thin textured slab per opaque icon pixel face; no shader tricks,
    /// works with any pipeline. 16 px = 1 model unit, grip scaled at draw time.
    private func itemGeom(_ stack: ItemStack) -> ModelGPU? {
        let def = itemDef(stack.id)
        if def.name == "shield" { return shieldGeom() }
        let key = "item:\(stack.id):\(stack.data.potion ?? "")"
        if let g = itemGeoms[key] { return g }
        let rgba = itemIconPixels(stack.id, stack.data)
        // icons are square but pack-dependent in size (16× vanilla, 32× Faithful…)
        let n = Int(Double(rgba.count / 4).squareRoot().rounded())
        guard n >= 8, n * n * 4 == rgba.count else { return nil }
        func solid(_ c: Int, _ r: Int) -> Bool {
            c >= 0 && c < n && r >= 0 && r < n && rgba[(r * n + c) * 4 + 3] > 96
        }
        var verts: [Float] = []
        let t: Float = 1.0 / 16 / 2   // half thickness in blocks (1 sprite px slab)
        func quad(_ c0: SIMD3<Float>, _ c1: SIMD3<Float>, _ c2: SIMD3<Float>, _ c3: SIMD3<Float>,
                  _ n: SIMD3<Float>, _ u: Float, _ v: Float) {
            let corners = [c0, c1, c2, c3]
            for i in [0, 2, 1, 0, 3, 2] {
                let p = corners[i]
                verts += [p.x, p.y, p.z, n.x, n.y, n.z, u, v, 0]
            }
        }
        let cell = 1.0 / Float(n)
        for r in 0..<n {
            for c in 0..<n where solid(c, r) {
                // sprite: column → x (centered), row 0 = top → y
                let x0 = Float(c) * cell - 0.5, x1 = x0 + cell
                let y1 = Float(n - r) * cell, y0 = y1 - cell
                let u = (Float(c) + 0.5) / Float(n), v = (Float(r) + 0.5) / Float(n)
                quad(.init(x0, y0, -t), .init(x1, y0, -t), .init(x1, y1, -t), .init(x0, y1, -t),
                     .init(0, 0, -1), u, v)
                quad(.init(x1, y0, t), .init(x0, y0, t), .init(x0, y1, t), .init(x1, y1, t),
                     .init(0, 0, 1), u, v)
                if !solid(c - 1, r) {
                    quad(.init(x0, y0, t), .init(x0, y0, -t), .init(x0, y1, -t), .init(x0, y1, t),
                         .init(-1, 0, 0), u, v)
                }
                if !solid(c + 1, r) {
                    quad(.init(x1, y0, -t), .init(x1, y0, t), .init(x1, y1, t), .init(x1, y1, -t),
                         .init(1, 0, 0), u, v)
                }
                if !solid(c, r - 1) {   // pixel above (higher y)
                    quad(.init(x0, y1, -t), .init(x1, y1, -t), .init(x1, y1, t), .init(x0, y1, t),
                         .init(0, 1, 0), u, v)
                }
                if !solid(c, r + 1) {   // pixel below
                    quad(.init(x0, y0, t), .init(x1, y0, t), .init(x1, y0, -t), .init(x0, y0, -t),
                         .init(0, -1, 0), u, v)
                }
            }
        }
        guard !verts.isEmpty else { return nil }
        let model = MobModel(texW: n, texH: n, parts: [ModelPart(name: "item", pivot: (0, 0, 0), boxes: [])],
                             anim: "none", scale: 1, paint: { _ in })
        let geom = EntityGeometry(verts: verts, vertexCount: verts.count / 9,
                                  partNames: ["item"], model: model,
                                  skin: EntitySkin(n, n, key))
        guard let g = makeGPU(geom, rgba, n, n) else { return nil }
        itemGeoms[key] = g
        return g
    }

    /// simple board shield (planks + iron boss), procedural texture
    private func shieldGeom() -> ModelGPU? {
        if let g = itemGeoms["shield"] { return g }
        let model = MobModel(texW: 32, texH: 32, parts: [
            ModelPart(name: "shield", pivot: (0, 0, 0), boxes: [ModelBox(-6, -11, -1, 12, 22, 1, 0, 0)]),
        ], anim: "none", scale: 1, paint: { s in
            s.box(0, 0, 12, 22, 1, 0x7a5b34, 0.1)      // oak planks
            s.rect(6, 2, 2, 22, 0x8a6b40)              // center plank stripe
            s.rect(5, 10, 4, 6, 0xb9bdc1)              // iron boss
            s.rect(6, 11, 2, 4, 0xd6dadd)
        })
        let built = buildEntityGeometry(from: model, skinName: "shield")
        guard let g = makeGPU(built, built.skin.data, built.skin.w, built.skin.h) else { return nil }
        itemGeoms["shield"] = g
        return g
    }

    // =========================================================================
    // draw pass — call straight after draw() for a player entity, while
    // partMats still holds that player's pose
    // =========================================================================
    func drawPlayerGear(_ enc: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState, sampler: MTLSamplerState,
                        viewProj: simd_float4x4, camPos: SIMD3<Double>, player: Player, p: EntityPose,
                        time: Double, dayLight: Double, fog: (color: SIMD3<Float>, start: Float, end: Float),
                        gamma: Double, ambient: Double) {
        // body pose is in partMats right now — capture the arms before armor re-poses
        let armR = partMats[2]
        let armL = partMats[3]

        var base = matrix_identity_float4x4
        base = mTranslate(base, Float(p.x - camPos.x), Float(p.y - camPos.y), Float(p.z - camPos.z))
        base = mRotateY(base, Float(.pi - p.yaw))
        let sc = Float(p.scale)
        base = mScale(base, sc, sc, sc)

        func submit(_ g: ModelGPU, _ modelM: simd_float4x4, _ mats: [simd_float4x4]) {
            var u = EntityUniforms(
                viewProj: viewProj,
                model: modelM,
                parts: (mats[0], mats[1], mats[2], mats[3], mats[4], mats[5], mats[6],
                        mats[7], mats[8], mats[9], mats[10], mats[11], mats[12], mats[13],
                        mats[14], mats[15], mats[16], mats[17], mats[18], mats[19],
                        mats[20], mats[21], mats[22], mats[23]),
                light: SIMD4<Float>(Float(p.sky), Float(p.block), Float(dayLight), Float(gamma)),
                misc: SIMD4<Float>(Float(ambient), Float(p.alpha), fog.start, fog.end),
                overlay: SIMD4<Float>(1, 0.2, 0.2, Float(p.hurtFlash * 0.5)),
                fogColor: SIMD4<Float>(fog.color.x, fog.color.y, fog.color.z, 1))
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(g.vb, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<EntityUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<EntityUniforms>.stride, index: 1)
            enc.setFragmentTexture(g.texture, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: g.count)
        }

        // ---- held items (part 0 of the item mesh rides the captured arm matrix)
        func heldMatrix(_ armMat: simd_float4x4, right: Bool, shield: Bool, raised: Bool) -> simd_float4x4 {
            var m = armMat
            if shield {
                // strapped flat to the forearm; swings up-front when blocking
                m = mTranslate(m, right ? -1.0 / 16 : 1.0 / 16, -9.0 / 16, raised ? -3.5 / 16 : 3.0 / 16)
                m = mRotateY(m, right ? 0.12 : -0.12)
                if raised { m = mRotateX(m, -0.15) }
            } else {
                // vanilla-style hold: blade plane slices forward, tilted
                // ~55° up-forward and a touch outward so it reads from behind
                m = mTranslate(m, right ? -1.5 / 16 : 1.5 / 16, -9.5 / 16, -1.0 / 16)
                m = mRotateZ(m, right ? 0.25 : -0.25)   // outward = -X for the right arm
                m = mRotateX(m, -0.7)
                m = mRotateY(m, right ? -.pi / 2 : .pi / 2)
                m = mScale(m, 0.7, 0.7, 0.7)
                m = mTranslate(m, 0, -0.12, 0)
            }
            return m
        }

        var idM = [simd_float4x4](repeating: matrix_identity_float4x4, count: 24)
        if let s = player.mainHand, let g = itemGeom(s) {
            let shield = itemDef(s.id).name == "shield"
            idM[0] = heldMatrix(armR, right: true, shield: shield, raised: p.blockingHand == "main")
            submit(g, base, idM)
        }
        if let s = player.offHand, let g = itemGeom(s) {
            let shield = itemDef(s.id).name == "shield"
            idM[0] = heldMatrix(armL, right: false, shield: shield, raised: p.blockingHand == "off")
            submit(g, base, idM)
        }

        // ---- armor overlays (each piece re-runs the shared animator)
        for piece in 0..<4 {
            guard player.armor.indices.contains(piece), let s = player.armor[piece],
                  let mat = Self.armorMaterial(s), let g = armorGeom(piece, mat) else { continue }
            pose(g, p, time)
            var mats = [simd_float4x4](repeating: matrix_identity_float4x4, count: 24)
            for i in 0..<24 { mats[i] = partMats[i] }
            submit(g, base, mats)
        }
    }

    // =========================================================================
    // first-person viewmodel — bare arm or held item in the bottom-right,
    // with swing / eat / draw / block animations (vanilla feel)
    // =========================================================================
    /// bare right arm textured with the current player skin
    private func fpArmGeom() -> ModelGPU? {
        if let g = itemGeoms["fp_arm"] { return g }
        let model = MobModel(texW: 64, texH: 64, parts: [
            ModelPart(name: "arm", pivot: (0, 0, 0), boxes: [ModelBox(-2, -12, -2, 4, 12, 4, 40, 16)]),
        ], anim: "none", scale: 1, paint: { _ in })
        let built = buildEntityGeometry(from: model, skinName: "fp_arm")
        guard let vb = built.verts.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: max(1, $0.count)) })
        else { return nil }
        // share the live player texture (custom skins included)
        let g = ModelGPU(vb: vb, count: built.vertexCount, texture: geom("player").texture, model: model)
        itemGeoms["fp_arm"] = g
        return g
    }

    func drawFirstPerson(_ enc: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState, sampler: MTLSamplerState,
                         proj: simd_float4x4, player: Player, timeSec: Double, dayLight: Double,
                         skyL: Int, blockL: Int, gamma: Double, ambient: Double) {
        let held = player.mainHand
        let heldDef = held.map { itemDef($0.id) }
        let isShield = heldDef?.name == "shield"
        let offShield = player.offHand.map { itemDef($0.id).name == "shield" } ?? false

        // swing arc: attackAnim decays 1 → 0, so progress f runs 0 → 1
        let f = max(0, 1 - Double(player.attackAnim))
        let swinging = player.attackAnim > 0.01
        let s1 = swinging ? Foundation.sin(f * .pi) : 0
        let s2 = swinging ? Foundation.sin(f.squareRoot() * .pi) : 0

        func submit(_ g: ModelGPU, _ m: simd_float4x4) {
            var u = EntityUniforms(
                viewProj: proj,
                model: m,
                parts: (matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4,
                        matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4,
                        matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4,
                        matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4,
                        matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4,
                        matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4,
                        matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4,
                        matrix_identity_float4x4, matrix_identity_float4x4, matrix_identity_float4x4),
                light: SIMD4<Float>(Float(skyL), Float(blockL), Float(dayLight), Float(gamma)),
                misc: SIMD4<Float>(Float(ambient), 1, 9999, 10000),   // no fog on the hand
                overlay: SIMD4<Float>(1, 0.2, 0.2, Float(player.hurtTime > 0 ? Double(player.hurtTime) / 10 * 0.5 : 0)),
                fogColor: SIMD4<Float>(0, 0, 0, 1))
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBuffer(g.vb, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<EntityUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<EntityUniforms>.stride, index: 1)
            enc.setFragmentTexture(g.texture, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: g.count)
        }

        // off-hand shield sits on the left edge (raised when blocking)
        if offShield, let g = itemGeom(player.offHand!) {
            let raised = player.usingItem && player.useItemHand == "off"
            var m = matrix_identity_float4x4
            m = mTranslate(m, raised ? -0.35 : -0.6, raised ? -0.35 : -0.62, -0.85)
            m = mRotateY(m, raised ? 0.55 : 0.85)
            m = mRotateZ(m, raised ? 0.05 : 0.12)
            let s: Float = raised ? 0.55 : 0.5
            m = mScale(m, s, s, s)
            submit(g, m)
        }

        var m = matrix_identity_float4x4
        if let held, let g = itemGeom(held) {
            if isShield {
                let raised = player.usingItem && player.useItemHand == "main"
                m = mTranslate(m, raised ? 0.35 : 0.6, raised ? -0.35 : -0.62, -0.85)
                m = mRotateY(m, raised ? -0.55 : -0.85)
                let s: Float = raised ? 0.55 : 0.5
                m = mScale(m, s, s, s)
                submit(g, m)
                return
            }
            // eating / drinking wiggle, bow draw pull
            var eat = 0.0, pull: Double = 0
            if player.usingItem && player.useItemHand == "main" {
                if heldDef?.food != nil || heldDef?.name == "potion" || heldDef?.name == "milk_bucket" {
                    eat = Foundation.sin(Double(player.useItemTicks) * 1.1) * 0.05 + 0.25
                } else if heldDef?.name == "bow" || heldDef?.name == "crossbow" {
                    pull = min(1, Double(player.useItemTicks) / 20)
                }
            }
            m = mTranslate(m,
                           Float(0.56 - s2 * 0.34 - eat * 0.9 - pull * 0.12),
                           Float(-0.5 - s1 * 0.2 + eat * 0.35),
                           Float(-0.72 - s1 * 0.05 + pull * 0.16))
            m = mRotateY(m, Float(0.15 - s2 * 1.05 + pull * 0.45))
            m = mRotateZ(m, Float(-s2 * 0.3))
            m = mRotateX(m, Float(-s1 * 0.85 + eat * 0.8))
            m = mScale(m, 0.62, 0.62, 0.62)
            submit(g, m)
        } else if held == nil, let g = fpArmGeom() {
            // empty fist: shoulder anchored off-screen bottom-right, forearm
            // rising diagonally toward the center (hand = the box's -Y end)
            m = mTranslate(m,
                           Float(0.78 - s2 * 0.35),
                           Float(-0.9 - s1 * 0.18),
                           Float(-0.55))
            m = mRotateY(m, Float(0.5 - s2 * 0.8))
            m = mRotateX(m, Float(2.25 - s1 * 0.9))
            m = mScale(m, 1.1, 1.1, 1.1)
            submit(g, m)
        }
    }
}
