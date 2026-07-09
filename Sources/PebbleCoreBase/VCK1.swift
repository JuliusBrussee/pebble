import Foundation

// centralized VCK1 chunk-container codec — portable, no host-endianness assumptions.
//
// today this container is duplicated in Sources/PebbleCore/Game/Saves.swift
// (encodeChunk/decodeChunk) and Sources/PebbleCore/Net/NetProtocol.swift
// (encodeChunkForWire/decodeWireChunk). Lane B/C swap those call sites over
// to this codec; do not edit Saves.swift or NetProtocol.swift here.
//
// wire layout:
//   "VCK1" magic | u8 flags | if flags&1 { u32 nBlocks, u16[nBlocks] LE, u32 nBiomes, u8[nBiomes] } | u32 jsonLen | json bytes
// all multi-byte integers are little-endian on the wire, independent of host byte order.

public struct VCK1Payload {
    public var blocks: [UInt16]?
    public var biomes: [UInt8]?
    public var json: Data

    public init(blocks: [UInt16]? = nil, biomes: [UInt8]? = nil, json: Data) {
        self.blocks = blocks
        self.biomes = biomes
        self.json = json
    }
}

public enum VCK1Error: Error, Equatable {
    case badMagic
    case truncated
    case overflow
    case badLength
}

public enum VCK1 {
    private static let magicBytes: [UInt8] = Array("VCK1".utf8)

    /// blocks+biomes are only written (flags|=1) when BOTH are present, matching the
    /// existing encodeChunk/encodeChunkForWire behavior. If only one is set, it is
    /// dropped rather than encoded inconsistently — encode() cannot fail, so callers
    /// that need a hard error for that case must validate before calling.
    public static func encode(_ p: VCK1Payload) -> Data {
        var data = Data()
        let hasBlocks = p.blocks != nil && p.biomes != nil
        data.reserveCapacity(4 + 1 + (hasBlocks ? 4 + (p.blocks!.count * 2) + 4 + p.biomes!.count : 0) + 4 + p.json.count)
        data.append(contentsOf: magicBytes)
        data.append(hasBlocks ? 1 : 0)
        if hasBlocks, let blocks = p.blocks, let biomes = p.biomes {
            appendU32LE(&data, UInt32(blocks.count))
            for v in blocks {
                data.append(UInt8(truncatingIfNeeded: v))
                data.append(UInt8(truncatingIfNeeded: v >> 8))
            }
            appendU32LE(&data, UInt32(biomes.count))
            data.append(contentsOf: biomes)
        }
        appendU32LE(&data, UInt32(p.json.count))
        data.append(p.json)
        return data
    }

    /// never traps: every length is bounds-checked against remaining bytes before use,
    /// and every u32 count is range-checked before it drives an allocation or index math.
    public static func decode(_ d: Data) throws -> VCK1Payload {
        let base = d.startIndex
        let end = d.endIndex
        var off = 0 // relative to `base` — `d` may be a slice with non-zero startIndex

        func remaining() -> Int { end - (base + off) }

        func readU32() throws -> Int {
            guard remaining() >= 4 else { throw VCK1Error.truncated }
            let b0 = UInt32(d[base + off])
            let b1 = UInt32(d[base + off + 1])
            let b2 = UInt32(d[base + off + 2])
            let b3 = UInt32(d[base + off + 3])
            off += 4
            let v = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
            // Int(exactly:) rather than Int(v): on a hypothetical 32-bit-Int platform,
            // a plain Int(v) would trap for v > Int32.max — decode must never trap.
            guard let n = Int(exactly: v) else { throw VCK1Error.badLength }
            return n
        }

        guard remaining() >= 5 else { throw VCK1Error.truncated }
        guard d[base..<(base + 4)].elementsEqual(magicBytes) else { throw VCK1Error.badMagic }
        off = 4

        let flags = d[base + off]
        off += 1

        var blocks: [UInt16]?
        var biomes: [UInt8]?

        if flags & 1 != 0 {
            let nBlocks = try readU32()
            let (blockBytes, overflowed) = nBlocks.multipliedReportingOverflow(by: 2)
            guard !overflowed else { throw VCK1Error.overflow }
            guard blockBytes >= 0, remaining() >= blockBytes else { throw VCK1Error.truncated }
            var bs = [UInt16]()
            bs.reserveCapacity(nBlocks)
            var i = 0
            while i < nBlocks {
                let lo = UInt16(d[base + off + i * 2])
                let hi = UInt16(d[base + off + i * 2 + 1])
                bs.append(lo | (hi << 8))
                i += 1
            }
            off += blockBytes
            blocks = bs

            let nBiomes = try readU32()
            guard nBiomes >= 0, remaining() >= nBiomes else { throw VCK1Error.truncated }
            biomes = [UInt8](d[(base + off)..<(base + off + nBiomes)])
            off += nBiomes
        }

        let jsonLen = try readU32()
        guard jsonLen >= 0, remaining() >= jsonLen else { throw VCK1Error.truncated }
        let json = Data(d[(base + off)..<(base + off + jsonLen)])
        off += jsonLen

        return VCK1Payload(blocks: blocks, biomes: biomes, json: json)
    }

    private static func appendU32LE(_ data: inout Data, _ v: UInt32) {
        data.append(UInt8(truncatingIfNeeded: v))
        data.append(UInt8(truncatingIfNeeded: v >> 8))
        data.append(UInt8(truncatingIfNeeded: v >> 16))
        data.append(UInt8(truncatingIfNeeded: v >> 24))
    }
}
