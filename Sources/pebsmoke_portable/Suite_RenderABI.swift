// Lane D03 smoke suite: byte-layout and draw-order checks for
// Sources/PebbleRenderABI. Suite name: "renderabi".
//
// Aggregator contract (pebsmoke_portable/main.swift, owned by another lane):
// call `RenderABISuite.run(check:)`, passing a closure with the same
// `(name: String, cond: Bool, detail: String) -> Void` shape used by
// Sources/pebsmoke_deterministic/main.swift's local `check` function, so a
// suite's pass/fail/count bookkeeping stays in one place (the aggregator).

import PebbleRenderABI

public enum RenderABISuite {
    public static let name = "renderabi"

    public static func run(check: (String, Bool, String) -> Void) {
        func eq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            check(name, got == want, "got \(got) want \(want)")
        }

        // -- RenderABI.version -------------------------------------------------
        eq("RenderABI.version", RenderABI.version, 1)

        // -- ABIMat4: 64 bytes, no padding --------------------------------------
        eq("ABIMat4 size", MemoryLayout<ABIMat4>.size, 64)
        eq("ABIMat4 stride", MemoryLayout<ABIMat4>.stride, 64)
        eq("ABIMat4 alignment", MemoryLayout<ABIMat4>.alignment, 16)
        eq("ABIMat4.stride constant", ABIMat4.stride, 64)

        // -- vertex structs: declared .stride/.layout MUST match the real
        // -- Swift/Metal memory layout, cross-checked via MemoryLayout.offset(of:)
        eq("ChunkVertex declared stride", ChunkVertex.stride, 28)
        eq("ChunkVertex MemoryLayout.size", MemoryLayout<ChunkVertex>.size, 28)
        eq("ChunkVertex MemoryLayout.stride", MemoryLayout<ChunkVertex>.stride, 28)
        eq("ChunkVertex offset(x)", MemoryLayout<ChunkVertex>.offset(of: \.x), 0)
        eq("ChunkVertex offset(u)", MemoryLayout<ChunkVertex>.offset(of: \.u), 12)
        eq("ChunkVertex offset(a)", MemoryLayout<ChunkVertex>.offset(of: \.a), 20)
        eq("ChunkVertex offset(b)", MemoryLayout<ChunkVertex>.offset(of: \.b), 24)
        eq("ChunkVertex.layout offsets", ChunkVertex.layout.map(\.offset), [0, 12, 20, 24])
        eq("ChunkVertex.layout formats", ChunkVertex.layout.map(\.format),
           [.float3, .float2, .uint1, .uint1])

        eq("StarVertex declared stride", StarVertex.stride, 16)
        eq("StarVertex MemoryLayout.stride", MemoryLayout<StarVertex>.stride, 16)
        eq("StarVertex offset(x)", MemoryLayout<StarVertex>.offset(of: \.x), 0)
        eq("StarVertex offset(mag)", MemoryLayout<StarVertex>.offset(of: \.mag), 12)
        eq("StarVertex.layout offsets", StarVertex.layout.map(\.offset), [0, 12])

        eq("EntityVertex declared stride", EntityVertex.stride, 36)
        eq("EntityVertex MemoryLayout.stride", MemoryLayout<EntityVertex>.stride, 36)
        eq("EntityVertex offset(x)", MemoryLayout<EntityVertex>.offset(of: \.x), 0)
        eq("EntityVertex offset(nx)", MemoryLayout<EntityVertex>.offset(of: \.nx), 12)
        eq("EntityVertex offset(u)", MemoryLayout<EntityVertex>.offset(of: \.u), 24)
        eq("EntityVertex offset(part)", MemoryLayout<EntityVertex>.offset(of: \.part), 32)
        eq("EntityVertex.layout offsets", EntityVertex.layout.map(\.offset), [0, 12, 24, 32])
        eq("ViewmodelVertex == EntityVertex", ViewmodelVertex.stride, EntityVertex.stride)

        eq("ParticleCornerVertex declared stride", ParticleCornerVertex.stride, 8)
        eq("ParticleCornerVertex MemoryLayout.stride", MemoryLayout<ParticleCornerVertex>.stride, 8)
        eq("ParticleCornerVertex offset(x)", MemoryLayout<ParticleCornerVertex>.offset(of: \.x), 0)

        eq("ParticleInstance declared stride", ParticleInstance.stride, 48)
        eq("ParticleInstance MemoryLayout.stride", MemoryLayout<ParticleInstance>.stride, 48)
        eq("ParticleInstance offset(x)", MemoryLayout<ParticleInstance>.offset(of: \.x), 0)
        eq("ParticleInstance offset(u0)", MemoryLayout<ParticleInstance>.offset(of: \.u0), 12)
        eq("ParticleInstance offset(layerSize)", MemoryLayout<ParticleInstance>.offset(of: \.layerSize), 28)
        eq("ParticleInstance offset(r)", MemoryLayout<ParticleInstance>.offset(of: \.r), 32)
        eq("ParticleInstance.layout offsets", ParticleInstance.layout.map(\.offset), [0, 12, 28, 32])

        eq("UIVertex declared stride", UIVertex.stride, 32)
        eq("UIVertex MemoryLayout.stride", MemoryLayout<UIVertex>.stride, 32)
        eq("UIVertex offset(x)", MemoryLayout<UIVertex>.offset(of: \.x), 0)
        eq("UIVertex offset(u)", MemoryLayout<UIVertex>.offset(of: \.u), 8)
        eq("UIVertex offset(r)", MemoryLayout<UIVertex>.offset(of: \.r), 16)
        eq("UIVertex.layout offsets", UIVertex.layout.map(\.offset), [0, 8, 16])

        // -- uniform structs: declared .stride MUST match MemoryLayout, and
        // -- must equal the hand-computed byte total from Shaders.swift ------
        func checkUniform<T>(_ name: String, _ type: T.Type, declared: Int, expected: Int) {
            eq("\(name) declared stride", declared, expected)
            eq("\(name) MemoryLayout.stride", MemoryLayout<T>.stride, expected)
            eq("\(name) MemoryLayout.size", MemoryLayout<T>.size, expected)
        }
        checkUniform("ChunkSharedUniforms", ChunkSharedUniforms.self, declared: ChunkSharedUniforms.stride, expected: 192)
        checkUniform("UltraUniforms", UltraUniforms.self, declared: UltraUniforms.stride, expected: 256)
        checkUniform("SkyUniforms", SkyUniforms.self, declared: SkyUniforms.stride, expected: 128)
        checkUniform("CelestialUniforms", CelestialUniforms.self, declared: CelestialUniforms.stride, expected: 112)
        checkUniform("StarsUniforms", StarsUniforms.self, declared: StarsUniforms.stride, expected: 80)
        checkUniform("CloudUniforms", CloudUniforms.self, declared: CloudUniforms.stride, expected: 96)
        checkUniform("LineUniforms", LineUniforms.self, declared: LineUniforms.stride, expected: 80)
        checkUniform("SpriteUniforms", SpriteUniforms.self, declared: SpriteUniforms.stride, expected: 144)
        checkUniform("CompositeUniforms", CompositeUniforms.self, declared: CompositeUniforms.stride, expected: 48)
        checkUniform("EntityUniforms", EntityUniforms.self, declared: EntityUniforms.stride, expected: 1728)
        checkUniform("ParticleUniforms", ParticleUniforms.self, declared: ParticleUniforms.stride, expected: 96)
        checkUniform("UIUniforms", UIUniforms.self, declared: UIUniforms.stride, expected: 16)
        checkUniform("LogoUniforms", LogoUniforms.self, declared: LogoUniforms.stride, expected: 16)
        checkUniform("TitleUniforms", TitleUniforms.self, declared: TitleUniforms.stride, expected: 16)
        eq("EntityUniforms.partCount", EntityUniforms.partCount, 24)
        eq("EntityUniforms offset(parts)", MemoryLayout<EntityUniforms>.offset(of: \.parts), 128)
        eq("EntityUniforms offset(light)", MemoryLayout<EntityUniforms>.offset(of: \.light), 128 + 24 * 64)

        // -- ShaderManifest: no duplicate names, no binding-slot collisions ----
        let names = ShaderManifest.pipelines.map(\.name)
        eq("ShaderManifest pipeline count", ShaderManifest.pipelines.count, 24)
        eq("ShaderManifest no duplicate names", Set(names).count, names.count)
        let ids = ShaderManifest.pipelines.map(\.id)
        eq("ShaderManifest no duplicate ids", Set(ids).count, ids.count)
        var collision = false
        for p in ShaderManifest.pipelines {
            var seen = Set<String>()
            for b in p.bindings {
                let key = "\(b.stage)/\(b.kind)/\(b.index)"
                if !seen.insert(key).inserted { collision = true }
            }
        }
        check("ShaderManifest no binding-slot collisions within a pipeline", !collision, "")
        check("ShaderManifest every pipeline has >=1 vertex function", ShaderManifest.pipelines.allSatisfy { !$0.vertexFunction.isEmpty }, "")

        // -- DrawItem / DrawSortKey: total, stable ordering ---------------------
        func item(_ pipeline: UInt32, _ mesh: UInt32, _ depth: UInt32, _ seq: UInt32) -> DrawItem {
            DrawItem(sortKey: DrawSortKey(pipeline: pipeline, depthBucket: depth, mesh: mesh, sequence: seq),
                     pipeline: PipelineID(raw: pipeline), meshHandle: MeshHandle(raw: mesh),
                     indexRange: 0..<0, instanceRange: 0..<1, textureBindings: [], pushConstants: [])
        }
        var unsorted: [DrawItem] = []
        for i in 0..<64 {
            let p: UInt32 = UInt32(i % 5)
            let m: UInt32 = UInt32((i * 7) % 11)
            let d: UInt32 = UInt32((i * 3) % 4)
            let s: UInt32 = UInt32(i)
            unsorted.append(item(p, m, d, s))
        }
        // the one canonical order every permutation of these items must sort back to
        let canonical = unsorted.sorted()

        // Fisher-Yates with a fixed LCG so the permutation is deterministic
        // across runs (no dependence on Swift's hash-seed-random Dictionary).
        func shuffledCopy(of items: [DrawItem], seed: UInt64) -> [DrawItem] {
            var copy = items
            var lcg = seed
            for i in stride(from: copy.count - 1, to: 0, by: -1) {
                lcg = lcg &* 6364136223846793005 &+ 1442695040888963407
                let j = Int(lcg % UInt64(i + 1))
                copy.swapAt(i, j)
            }
            return copy
        }
        let shuffleA = shuffledCopy(of: unsorted, seed: 0x1234_5678)
        let shuffleB = shuffledCopy(of: canonical, seed: 0x9E37_79B9)
        check("DrawItem shuffle actually reordered the array",
              shuffleA.map(\.sortKey.sequence) != canonical.map(\.sortKey.sequence), "")
        eq("DrawItem sort totality: shuffled array A sorts back to canonical order",
           shuffleA.sorted().map(\.sortKey.sequence), canonical.map(\.sortKey.sequence))
        eq("DrawItem sort totality: shuffled array B sorts back to canonical order",
           shuffleB.sorted().map(\.sortKey.sequence), canonical.map(\.sortKey.sequence))
        let resortedTwice = canonical.sorted()
        eq("DrawItem sort idempotence", resortedTwice.map(\.sortKey.sequence), canonical.map(\.sortKey.sequence))
        // strict total order: every distinct pair is comparable and exactly one way
        var noTies = true
        var asymmetric = true
        for i in 0..<canonical.count where i > 0 {
            let a = canonical[i - 1].sortKey, b = canonical[i].sortKey
            if !(a < b || b < a) { noTies = false }
            if a < b && b < a { asymmetric = false }
        }
        check("DrawSortKey strict total order (unique sequence never ties)", noTies, "")
        check("DrawSortKey antisymmetric (never a<b and b<a)", asymmetric, "")
        eq("RenderPass.Kind canonical pass order", RenderPass.Kind.allCases,
           [.shadow, .world, .entities, .particles, .ui, .postprocess])

        // -- Capture ------------------------------------------------------------
        let cap = CaptureImage(width: 4, height: 2, bytesPerRow: 16, format: .bgra8UnormOpaque,
                                origin: .topLeft, pixels: [UInt8](repeating: 0, count: 32))
        eq("CaptureImage bytesPerRow == width*4 (tightly packed)", cap.bytesPerRow, cap.width * 4)
        eq("CaptureImage pixel buffer sized for bytesPerRow*height", cap.pixels.count, cap.bytesPerRow * cap.height)
    }
}
