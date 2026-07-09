// DEFLATE (RFC 1951) decompressor + a thin RFC 1950 zlib wrapper. Pure Swift,
// no Compression/zlib linkage. Allocation-bounded: every write to the output
// buffer is checked against a caller-supplied cap first, so a hostile stream
// can never force an unbounded allocation. Never traps: every bit read, every
// length/distance/index is bounds-checked before use — malformed input always
// surfaces as a thrown InflateError/ZlibError, never an array-index crash.

public enum InflateError: Error, Equatable {
    case truncated                  // ran out of input bits/bytes mid-stream
    case badBlockType               // BTYPE == 3 (reserved)
    case badStoredBlockLength       // stored block's LEN/NLEN don't complement
    case incompleteHuffmanTable     // Huffman code under- or over-subscribed
    case badSymbol                  // decoded a literal/length/distance symbol outside its valid range
    case badDistance                // back-reference distance is 0, or reaches before the start of output
    case outputTooLarge             // would exceed the caller's maxOutputBytes
}

public enum Inflate {
    /// decompress a raw DEFLATE stream (no zlib/gzip wrapper). Throws rather than
    /// traps on any malformed input; stops with .outputTooLarge before ever writing
    /// past maxOutputBytes.
    public static func inflate(_ input: [UInt8], maxOutputBytes: Int) throws -> [UInt8] {
        try inflateCore(input, startByte: 0, maxOutputBytes: maxOutputBytes).output
    }

    /// same as inflate(_:maxOutputBytes:), but also reports how many input bytes
    /// were consumed — used by Zlib.inflate to locate the trailing Adler-32 exactly,
    /// regardless of any padding after the DEFLATE stream.
    static func inflateCore(_ input: [UInt8], startByte: Int, maxOutputBytes: Int) throws -> (output: [UInt8], consumedBytes: Int) {
        var reader = BitReader(input, startByte: startByte)
        var output: [UInt8] = []
        output.reserveCapacity(min(maxOutputBytes, max(input.count * 3, 64)))

        var isFinal = false
        repeat {
            isFinal = try reader.bit() != 0
            let type = try reader.bits(2)
            switch type {
            case 0:
                try inflateStored(&reader, &output, maxOutputBytes)
            case 1:
                try inflateHuffmanBlock(&reader, &output, maxOutputBytes, fixedLit, fixedDist)
            case 2:
                let (lit, dist) = try readDynamicTables(&reader)
                try inflateHuffmanBlock(&reader, &output, maxOutputBytes, lit, dist)
            default:
                throw InflateError.badBlockType
            }
        } while !isFinal

        return (output, reader.bytePos)
    }

    // ---- stored (uncompressed) block ---------------------------------------

    private static func inflateStored(_ reader: inout BitReader, _ output: inout [UInt8], _ maxOutputBytes: Int) throws {
        reader.alignToByte()
        guard let lo = reader.byte(), let hi = reader.byte(),
              let nlo = reader.byte(), let nhi = reader.byte() else { throw InflateError.truncated }
        let len = Int(lo) | (Int(hi) << 8)
        let nlen = Int(nlo) | (Int(nhi) << 8)
        guard (len ^ 0xFFFF) == nlen else { throw InflateError.badStoredBlockLength }
        guard output.count + len <= maxOutputBytes else { throw InflateError.outputTooLarge }
        for _ in 0..<len {
            guard let b = reader.byte() else { throw InflateError.truncated }
            output.append(b)
        }
    }

    // ---- Huffman-coded (fixed or dynamic) block -----------------------------

    private static func inflateHuffmanBlock(_ reader: inout BitReader, _ output: inout [UInt8], _ maxOutputBytes: Int,
                                            _ lit: Huffman, _ dist: Huffman) throws {
        while true {
            let sym = try lit.decode(&reader)
            if sym < 256 {
                guard output.count < maxOutputBytes else { throw InflateError.outputTooLarge }
                output.append(UInt8(sym))
            } else if sym == 256 {
                return
            } else {
                let idx = sym - 257
                guard idx < lengthBase.count else { throw InflateError.badSymbol }
                let extra = try reader.bits(lengthExtra[idx])
                let length = lengthBase[idx] + extra

                let distSym = try dist.decode(&reader)
                guard distSym < distBase.count else { throw InflateError.badSymbol }
                let dExtra = try reader.bits(distExtra[distSym])
                let distance = distBase[distSym] + dExtra

                guard distance >= 1, distance <= output.count else { throw InflateError.badDistance }
                guard output.count + length <= maxOutputBytes else { throw InflateError.outputTooLarge }
                var src = output.count - distance
                for _ in 0..<length {
                    output.append(output[src])
                    src += 1
                }
            }
        }
    }

    // ---- dynamic Huffman table header ---------------------------------------

    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static func readDynamicTables(_ reader: inout BitReader) throws -> (lit: Huffman, dist: Huffman) {
        let hlit = try reader.bits(5) + 257
        let hdist = try reader.bits(5) + 1
        let hclen = try reader.bits(4) + 4

        var clLengths = [Int](repeating: 0, count: 19)
        for i in 0..<hclen {
            clLengths[codeLengthOrder[i]] = try reader.bits(3)
        }
        let clTable = try Huffman(lengths: clLengths)

        var lengths = [Int](repeating: 0, count: hlit + hdist)
        var i = 0
        while i < lengths.count {
            let sym = try clTable.decode(&reader)
            switch sym {
            case 0...15:
                lengths[i] = sym
                i += 1
            case 16:
                guard i > 0 else { throw InflateError.badSymbol }
                let repeatCount = try reader.bits(2) + 3
                guard i + repeatCount <= lengths.count else { throw InflateError.badSymbol }
                let prev = lengths[i - 1]
                for _ in 0..<repeatCount { lengths[i] = prev; i += 1 }
            case 17:
                let repeatCount = try reader.bits(3) + 3
                guard i + repeatCount <= lengths.count else { throw InflateError.badSymbol }
                for _ in 0..<repeatCount { lengths[i] = 0; i += 1 }
            case 18:
                let repeatCount = try reader.bits(7) + 11
                guard i + repeatCount <= lengths.count else { throw InflateError.badSymbol }
                for _ in 0..<repeatCount { lengths[i] = 0; i += 1 }
            default:
                throw InflateError.badSymbol
            }
        }

        let lit = try Huffman(lengths: Array(lengths[0..<hlit]))
        let dist = try Huffman(lengths: Array(lengths[hlit...]))
        return (lit, dist)
    }

    // ---- fixed Huffman tables (RFC 1951 3.2.6) -------------------------------

    private static let fixedLit: Huffman = {
        var lengths = [Int](repeating: 8, count: 144)
        lengths += [Int](repeating: 9, count: 112)
        lengths += [Int](repeating: 7, count: 24)
        lengths += [Int](repeating: 8, count: 8)
        return Huffman.fixed(lengths)
    }()

    private static let fixedDist: Huffman = Huffman.fixed([Int](repeating: 5, count: 30))

    // ---- length/distance extra-bits tables (RFC 1951 3.2.5) -----------------

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
}

// =============================================================================
// canonical Huffman decode table (RFC 1951 3.2.2), the standard counts/symbols
// construction — builds once per table, decodes one bit at a time in O(code length).
// =============================================================================
struct Huffman {
    private let counts: [Int]    // counts[len] = number of codes of that length, len 1...15
    private let symbols: [Int]   // symbols in canonical code order

    static let maxBits = 15

    /// throws .incompleteHuffmanTable for an over- or (illegally) under-subscribed
    /// code. The one exception RFC 1951 permits — a single code of length 1 (used
    /// for a distance table when a block has no back-references at all) — is
    /// allowed through, matching every real-world deflate encoder. Used for the
    /// dynamic-block tables, which are untrusted (attacker-controlled) input.
    init(lengths: [Int]) throws {
        var counts = [Int](repeating: 0, count: Huffman.maxBits + 1)
        for len in lengths {
            guard len >= 0, len <= Huffman.maxBits else { throw InflateError.incompleteHuffmanTable }
            counts[len] += 1
        }
        if counts[0] != lengths.count {
            var left = 1
            for len in 1...Huffman.maxBits {
                left <<= 1
                left -= counts[len]
                guard left >= 0 else { throw InflateError.incompleteHuffmanTable }
            }
            if left > 0 {
                let onlyLengthOneUsed = lengths.count == counts[0] + counts[1]
                guard onlyLengthOneUsed else { throw InflateError.incompleteHuffmanTable }
            }
        }
        (self.counts, self.symbols) = Huffman.build(lengths, counts)
    }

    /// unchecked construction for RFC 1951's fixed tables (3.2.6), which are
    /// spec-mandated constants, not attacker-controlled: the fixed distance
    /// table is legitimately under-subscribed (only 30 of 32 possible 5-bit
    /// codes are ever assigned; the other two are reserved and simply never
    /// decode), so the dynamic-table completeness check does not apply here.
    private init(fixedLengths lengths: [Int]) {
        var counts = [Int](repeating: 0, count: Huffman.maxBits + 1)
        for len in lengths { counts[len] += 1 }
        (self.counts, self.symbols) = Huffman.build(lengths, counts)
    }

    static func fixed(_ lengths: [Int]) -> Huffman {
        Huffman(fixedLengths: lengths)
    }

    private static func build(_ lengths: [Int], _ counts: [Int]) -> (counts: [Int], symbols: [Int]) {
        var offsets = [Int](repeating: 0, count: Huffman.maxBits + 2)
        for len in 1..<Huffman.maxBits { offsets[len + 1] = offsets[len] + counts[len] }
        var symbols = [Int](repeating: 0, count: lengths.count - counts[0])
        for (symbol, len) in lengths.enumerated() where len != 0 {
            symbols[offsets[len]] = symbol
            offsets[len] += 1
        }
        return (counts, symbols)
    }

    func decode(_ reader: inout BitReader) throws -> Int {
        var code = 0, first = 0, index = 0
        for len in 1...Huffman.maxBits {
            code |= try reader.bit()
            let count = counts[len]
            if code - first < count {
                return symbols[index + (code - first)]
            }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw InflateError.incompleteHuffmanTable
    }
}

// =============================================================================
// LSB-first bit reader over a byte array. Regular multi-bit fields (extra bits,
// stored-block lengths, HLIT/HDIST/HCLEN) are packed LSB-first; Huffman codes are
// packed MSB-first, which Huffman.decode() handles itself bit-by-bit.
// =============================================================================
struct BitReader {
    private let bytes: [UInt8]
    private(set) var bytePos: Int
    private var bitBuf: UInt32 = 0
    private var bitCount: Int = 0

    init(_ bytes: [UInt8], startByte: Int) {
        self.bytes = bytes
        self.bytePos = startByte
    }

    mutating func bit() throws -> Int {
        if bitCount == 0 {
            guard bytePos < bytes.count else { throw InflateError.truncated }
            bitBuf = UInt32(bytes[bytePos])
            bytePos += 1
            bitCount = 8
        }
        let b = Int(bitBuf & 1)
        bitBuf >>= 1
        bitCount -= 1
        return b
    }

    mutating func bits(_ n: Int) throws -> Int {
        var v = 0
        var i = 0
        while i < n {
            v |= try bit() << i
            i += 1
        }
        return v
    }

    /// discard any partial byte in the bit buffer (block-header alignment for stored blocks)
    mutating func alignToByte() {
        bitBuf = 0
        bitCount = 0
    }

    /// whole byte, only valid once alignToByte() has been called
    mutating func byte() -> UInt8? {
        guard bytePos < bytes.count else { return nil }
        let b = bytes[bytePos]
        bytePos += 1
        return b
    }
}
