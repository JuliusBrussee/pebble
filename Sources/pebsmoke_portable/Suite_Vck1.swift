import Foundation
import PebbleCoreBase

/// exercises the centralized VCK1 codec directly — see Sources/PebbleCoreBase/VCK1.swift.
public struct Vck1Suite: PortableSuite {
    public static let name = "vck1"

    // hand-verified wire bytes for:
    //   blocks=[0x0001, 0x0203], biomes=[0x10, 0x20, 0x30], json={"a":1}
    private static let goldenPayload = VCK1Payload(
        blocks: [0x0001, 0x0203],
        biomes: [0x10, 0x20, 0x30],
        json: Data("{\"a\":1}".utf8)
    )
    private static let goldenBytes: [UInt8] = [
        0x56, 0x43, 0x4B, 0x31, // "VCK1" magic
        0x01,                   // flags = has blocks/biomes
        0x02, 0x00, 0x00, 0x00, // nBlocks = 2 LE
        0x01, 0x00,             // block[0] = 0x0001 LE
        0x03, 0x02,             // block[1] = 0x0203 LE
        0x03, 0x00, 0x00, 0x00, // nBiomes = 3 LE
        0x10, 0x20, 0x30,       // biomes
        0x07, 0x00, 0x00, 0x00, // jsonLen = 7 LE
        0x7B, 0x22, 0x61, 0x22, 0x3A, 0x31, 0x7D, // {"a":1}
    ]

    public static func run(_ h: inout SmokeHarness) {
        // round-trip with blocks/biomes
        let withBlocksEnc = VCK1.encode(goldenPayload)
        if let decoded = try? VCK1.decode(withBlocksEnc) {
            h.eq("round-trip blocks", decoded.blocks, goldenPayload.blocks)
            h.eq("round-trip biomes", decoded.biomes, goldenPayload.biomes)
            h.eq("round-trip json", decoded.json, goldenPayload.json)
        } else {
            h.check("round-trip blocks", false)
            h.check("round-trip biomes", false)
            h.check("round-trip json", false)
        }

        // round-trip without blocks (flags = 0)
        let noBlocksPayload = VCK1Payload(json: Data("hello".utf8))
        let noBlocksEnc = VCK1.encode(noBlocksPayload)
        if let decoded = try? VCK1.decode(noBlocksEnc) {
            h.check("round-trip no-blocks blocks nil", decoded.blocks == nil)
            h.check("round-trip no-blocks biomes nil", decoded.biomes == nil)
            h.eq("round-trip no-blocks json", decoded.json, noBlocksPayload.json)
        } else {
            h.check("round-trip no-blocks blocks nil", false)
            h.check("round-trip no-blocks biomes nil", false)
            h.check("round-trip no-blocks json", false)
        }

        // golden byte pin — wire format must not silently drift
        h.eq("golden encode bytes", withBlocksEnc, Data(goldenBytes))
        if let decodedGolden = try? VCK1.decode(Data(goldenBytes)) {
            h.eq("golden decode blocks", decodedGolden.blocks, goldenPayload.blocks)
            h.eq("golden decode biomes", decodedGolden.biomes, goldenPayload.biomes)
            h.eq("golden decode json", decodedGolden.json, goldenPayload.json)
        } else {
            h.check("golden decode blocks", false)
            h.check("golden decode biomes", false)
            h.check("golden decode json", false)
        }

        // bad magic
        h.check("bad magic throws", throwsVck1Error(Data("XXXX\u{0}".utf8), .badMagic))

        // truncated header (< 5 bytes total)
        h.check("truncated header throws", throwsVck1Error(Data([0x56, 0x43, 0x4B]), .truncated))

        // truncated blocks: claims nBlocks=5 but only 2 bytes of block data follow
        var truncBlocks = Data("VCK1".utf8)
        truncBlocks.append(1) // flags
        truncBlocks.append(contentsOf: [0x05, 0x00, 0x00, 0x00]) // nBlocks = 5
        truncBlocks.append(contentsOf: [0x00, 0x00]) // only 1 block worth of bytes, need 10
        h.check("truncated blocks throws", throwsVck1Error(truncBlocks, .truncated))

        // truncated json: header says jsonLen=100 but nothing follows
        var truncJson = Data("VCK1".utf8)
        truncJson.append(0) // flags = no blocks
        truncJson.append(contentsOf: [0x64, 0x00, 0x00, 0x00]) // jsonLen = 100
        h.check("truncated json throws", throwsVck1Error(truncJson, .truncated))

        // huge nBlocks (u32 max) relative to a tiny buffer must be rejected cleanly,
        // never attempt to allocate ~8GB or crash — this is the overflow/bounds guard
        var hugeCount = Data("VCK1".utf8)
        hugeCount.append(1) // flags
        hugeCount.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // nBlocks = UInt32.max
        var hugeCountThrew = false
        do {
            _ = try VCK1.decode(hugeCount)
        } catch {
            hugeCountThrew = true
        }
        h.check("huge u32 count rejected without crash", hugeCountThrew)

        // non-zero startIndex Data slice must decode correctly (indices relative to startIndex)
        var prefixed = Data([0xFF, 0xEE, 0xDD])
        prefixed.append(withBlocksEnc)
        let sliceStart = prefixed.startIndex + 3
        let slice = prefixed[sliceStart...]
        h.check("non-zero-startIndex slice startIndex", slice.startIndex != 0)
        if let decodedSlice = try? VCK1.decode(slice) {
            h.eq("non-zero-startIndex slice decode blocks", decodedSlice.blocks, goldenPayload.blocks)
            h.eq("non-zero-startIndex slice decode json", decodedSlice.json, goldenPayload.json)
        } else {
            h.check("non-zero-startIndex slice decode blocks", false)
            h.check("non-zero-startIndex slice decode json", false)
        }
    }

    private static func throwsVck1Error(_ data: Data, _ expected: VCK1Error) -> Bool {
        do {
            _ = try VCK1.decode(data)
            return false
        } catch let e as VCK1Error {
            return e == expected
        } catch {
            return false
        }
    }
}
