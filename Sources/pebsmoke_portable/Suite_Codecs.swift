import Foundation
import PebbleCodecs

/// exercises Inflate/Zlib/PNG/Zip directly. Every fixture is built in code
/// (bit-level writers below, or hand-computed filter bytes in comments) so
/// this suite depends on nothing outside this file: no repo assets, no data
/// root, no external zlib/libpng to cross-check against.
public struct CodecsSuite: PortableSuite {
    public static let name = "codecs"

    public static func run(_ h: inout SmokeHarness) {
        runInflateChecks(&h)
        runZlibChecks(&h)
        runChecksumChecks(&h)
        runPNGChecks(&h)
        runZipChecks(&h)
    }

    // =========================================================================
    // MARK: - Inflate (raw DEFLATE)
    // =========================================================================

    private static func runInflateChecks(_ h: inout SmokeHarness) {
        // stored block: BFINAL=1,BTYPE=00 (byte-aligned header = 0x01), LEN=2, NLEN=~LEN, "hi"
        let stored: [UInt8] = [0x01, 0x02, 0x00, 0xFD, 0xFF, 0x68, 0x69]
        if let out = try? Inflate.inflate(stored, maxOutputBytes: 64) {
            h.eq("inflate: stored block", out, [0x68, 0x69])
        } else {
            h.check("inflate: stored block", false)
        }

        // fixed-Huffman block: literals 'A','B' then end-of-block, via the real
        // canonical fixed-Huffman table (built with the same canonicalCodes()
        // algorithm the dynamic-block encoder below uses)
        var fw = TestBitWriter()
        fw.writeBit(1)                    // BFINAL=1
        fw.writeBitsLSBFirst(1, 2)        // BTYPE=01 (fixed)
        fw.writeSymbol(fixedLitTable, 65)  // 'A'
        fw.writeSymbol(fixedLitTable, 66)  // 'B'
        fw.writeSymbol(fixedLitTable, 256) // end-of-block
        if let out = try? Inflate.inflate(fw.finished(), maxOutputBytes: 64) {
            h.eq("inflate: fixed-Huffman block", out, [65, 66])
        } else {
            h.check("inflate: fixed-Huffman block", false)
        }

        // dynamic-Huffman block: minimal 2-symbol lit/length table (literal 'X'
        // and end-of-block, both length-1 codes) with an empty distance table
        // (no back-references used) — see buildMinimalDynamicBlock() below.
        let dyn = buildMinimalDynamicBlock(literal: 0x58) // 'X'
        if let out = try? Inflate.inflate(dyn, maxOutputBytes: 64) {
            h.eq("inflate: dynamic-Huffman block", out, [0x58])
        } else {
            h.check("inflate: dynamic-Huffman block", false)
        }

        // empty stream: nothing to even read BFINAL/BTYPE from
        h.check("inflate: empty stream throws", throwsInflate([], 64))

        // truncated stream: stored block claims LEN=10 but only 2 bytes follow
        let truncatedStored: [UInt8] = [0x01, 0x0A, 0x00, 0xF5, 0xFF, 0x00, 0x00]
        h.check("inflate: truncated stream throws", throwsInflate(truncatedStored, 64))

        // bad block type: BFINAL=1, BTYPE=11 (reserved)
        var bw = TestBitWriter()
        bw.writeBit(1)
        bw.writeBitsLSBFirst(3, 2)
        h.check("inflate: bad block type throws", throwsInflate(bw.finished(), 64))

        // distance-too-far: literal 'A' (1 byte of output), then a length/distance
        // back-reference to distance=5 — but only 1 byte has been produced so far
        var dtf = TestBitWriter()
        dtf.writeBit(1)
        dtf.writeBitsLSBFirst(1, 2)         // fixed Huffman
        dtf.writeSymbol(fixedLitTable, 65)   // 'A'
        dtf.writeSymbol(fixedLitTable, 257)  // length code idx0 -> length 3, 0 extra bits
        dtf.writeSymbol(fixedDistTable, 4)   // distance code 4 -> distance base 5, 0 extra bits
        dtf.writeSymbol(fixedLitTable, 256)  // end-of-block (unreachable if it throws first)
        h.check("inflate: distance-too-far throws", throwsInflate(dtf.finished(), 64))

        // output cap exceeded: 5 literals + EOB, decoded with a 3-byte cap
        var cap = TestBitWriter()
        cap.writeBit(1)
        cap.writeBitsLSBFirst(1, 2)
        for lit: UInt8 in [1, 2, 3, 4, 5] { cap.writeSymbol(fixedLitTable, Int(lit)) }
        cap.writeSymbol(fixedLitTable, 256)
        h.check("inflate: output cap exceeded throws", throwsInflate(cap.finished(), 3))
    }

    private static func throwsInflate(_ bytes: [UInt8], _ cap: Int) -> Bool {
        do { _ = try Inflate.inflate(bytes, maxOutputBytes: cap); return false }
        catch { return true }
    }

    // =========================================================================
    // MARK: - Zlib (RFC 1950 wrapper)
    // =========================================================================

    private static func runZlibChecks(_ h: inout SmokeHarness) {
        let raw: [UInt8] = Array("hello, pebble".utf8)
        let good = zlibStoredWrap(raw)
        if let out = try? Zlib.inflate(good, maxOutputBytes: 64) {
            h.eq("zlib: good header round-trip", out, raw)
        } else {
            h.check("zlib: good header round-trip", false)
        }

        // bad CMF/FLG: FCHECK fails ((CMF*256+FLG) % 31 != 0)
        let badHeader: [UInt8] = [0x78, 0x00, 0x00, 0x00]
        h.check("zlib: bad CMF/header throws", throwsZlib(badHeader, 64))

        // Adler mismatch: valid header + body, corrupted trailing checksum byte
        var corrupted = good
        corrupted[corrupted.count - 1] ^= 0xFF
        h.check("zlib: Adler mismatch throws", throwsZlib(corrupted, 64))
    }

    private static func throwsZlib(_ bytes: [UInt8], _ cap: Int) -> Bool {
        do { _ = try Zlib.inflate(bytes, maxOutputBytes: cap); return false }
        catch { return true }
    }

    /// wraps raw bytes as a minimal valid zlib stream using stored (uncompressed)
    /// DEFLATE blocks — independent of PNG.swift's private encoder, so a bug in
    /// one doesn't mask a bug in the other.
    private static func zlibStoredWrap(_ raw: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        if raw.isEmpty {
            out.append(contentsOf: [1, 0, 0, 0xFF, 0xFF])
        } else {
            var offset = 0
            while offset < raw.count {
                let len = min(65535, raw.count - offset)
                let isFinal = offset + len == raw.count
                out.append(isFinal ? 1 : 0)
                let l = UInt16(len), nl = ~l
                out.append(UInt8(l & 0xFF)); out.append(UInt8(l >> 8))
                out.append(UInt8(nl & 0xFF)); out.append(UInt8(nl >> 8))
                out.append(contentsOf: raw[offset..<(offset + len)])
                offset += len
            }
        }
        let adler = Adler32.checksum(raw)
        out.append(UInt8((adler >> 24) & 0xFF)); out.append(UInt8((adler >> 16) & 0xFF))
        out.append(UInt8((adler >> 8) & 0xFF)); out.append(UInt8(adler & 0xFF))
        return out
    }

    // =========================================================================
    // MARK: - CRC32 / Adler32 known test vectors
    // =========================================================================

    private static func runChecksumChecks(_ h: inout SmokeHarness) {
        // the standard CRC-32/ISO-HDLC check value
        h.eq("crc32: known vector \"123456789\"", CRC32.of(Array("123456789".utf8)), 0xCBF43926)
        // widely-cited Adler-32 check value
        h.eq("adler32: known vector \"Wikipedia\"", Adler32.checksum(Array("Wikipedia".utf8)), 0x11E60398)
    }

    // =========================================================================
    // MARK: - PNG
    // =========================================================================

    private static func runPNGChecks(_ h: inout SmokeHarness) {
        // ---- 2x2 RGBA -----------------------------------------------------
        let rgbaRaw: [UInt8] = [
            0, 255, 0, 0, 255, 0, 255, 0, 128,          // row0: filter None, red, green(a=128)
            0, 0, 0, 255, 64, 255, 255, 255, 255,       // row1: filter None, blue(a=64), white
        ]
        let rgbaPNG = buildPNG(width: 2, height: 2, colorType: 6, raw: rgbaRaw)
        if let img = try? PNG.decode(rgbaPNG) {
            h.eq("png: 2x2 RGBA width/height", [img.width, img.height], [2, 2])
            h.eq("png: 2x2 RGBA pixels", img.pixels, [
                255, 0, 0, 255,   0, 255, 0, 128,
                0, 0, 255, 64,    255, 255, 255, 255,
            ])
        } else {
            h.check("png: 2x2 RGBA width/height", false)
            h.check("png: 2x2 RGBA pixels", false)
        }

        // ---- palette + tRNS -------------------------------------------------
        // 2x1 indexed image: palette[0]=red (tRNS alpha 128), palette[1]=green (opaque)
        let paletteRaw: [UInt8] = [0, 0, 1]   // filter None, idx0, idx1
        let palettePNG = buildPNG(width: 2, height: 1, colorType: 3, raw: paletteRaw,
                                  extraChunks: [
                                    ("PLTE", [255, 0, 0, 0, 255, 0]),
                                    ("tRNS", [128, 255]),
                                  ])
        if let img = try? PNG.decode(palettePNG) {
            h.eq("png: palette+tRNS pixels", img.pixels, [255, 0, 0, 128, 0, 255, 0, 255])
        } else {
            h.check("png: palette+tRNS pixels", false)
        }

        // ---- all 5 row filters (grayscale, 3 wide x 5 tall) ------------------
        // target decoded gray values per row, hand-derived from each filter's
        // reconstruction formula against the previous row/column (see inline math):
        //   row0 None:    [10, 20, 30]
        //   row1 Sub:     [15, 25, 35]
        //   row2 Up:      [12, 22, 33]
        //   row3 Average: [50, 60, 70]
        //   row4 Paeth:   [ 5, 100, 200]
        let filterRaw: [UInt8] = [
            0, 10, 20, 30,
            1, 15, 10, 10,
            2, 253, 253, 254,
            3, 44, 24, 24,
            4, 211, 95, 100,
        ]
        let filterPNG = buildPNG(width: 3, height: 5, colorType: 0, raw: filterRaw)
        if let img = try? PNG.decode(filterPNG) {
            let expectedGray: [UInt8] = [10, 20, 30, 15, 25, 35, 12, 22, 33, 50, 60, 70, 5, 100, 200]
            var got: [UInt8] = []
            for i in 0..<15 { got.append(img.pixels[i * 4]) }
            h.eq("png: all 5 filter types (grayscale) decode", got, expectedGray)
            h.check("png: filtered image alpha is opaque", img.pixels.indices.filter { $0 % 4 == 3 }.allSatisfy { img.pixels[$0] == 255 })
        } else {
            h.check("png: all 5 filter types (grayscale) decode", false)
            h.check("png: filtered image alpha is opaque", false)
        }

        // ---- bad magic ------------------------------------------------------
        h.check("png: bad magic throws", throwsPNG([UInt8](repeating: 0, count: 16)))

        // ---- truncated IDAT ---------------------------------------------------
        var truncated = pngSignatureAndIHDR(width: 2, height: 2, colorType: 6)
        var idatHeader: [UInt8] = []
        appendU32BE(&idatHeader, 100) // claims 100 bytes of IDAT data
        idatHeader.append(contentsOf: Array("IDAT".utf8))
        idatHeader.append(contentsOf: [0, 1, 2, 3, 4]) // only 5 actual bytes, then EOF — no CRC
        truncated.append(contentsOf: idatHeader)
        h.check("png: truncated IDAT throws", throwsPNG(truncated))

        // ---- bad CRC on a chunk -----------------------------------------------
        var badCRC = rgbaPNG
        badCRC[badCRC.count - 1] ^= 0xFF // flip a byte inside the trailing IEND chunk's CRC field
        h.check("png: bad chunk CRC throws", throwsPNG(badCRC))

        // ---- 16-bit rejected --------------------------------------------------
        h.check("png: 16-bit depth rejected", throwsPNG(pngSignatureAndIHDR(width: 2, height: 2, colorType: 6, bitDepth: 16)))

        // ---- interlaced rejected ------------------------------------------------
        h.check("png: Adam7 interlace rejected", throwsPNG(pngSignatureAndIHDR(width: 2, height: 2, colorType: 6, interlace: 1)))

        // ---- huge dimensions rejected -------------------------------------------
        h.check("png: huge dimensions rejected", throwsPNG(pngSignatureAndIHDR(width: 100_000, height: 100_000, colorType: 6)))

        // ---- encode -> decode round trip, 3x5, non-trivial pixels ----------------
        var pixels = [UInt8](repeating: 0, count: 3 * 5 * 4)
        for i in 0..<(3 * 5) {
            pixels[i * 4] = UInt8((i * 37) % 256)
            pixels[i * 4 + 1] = UInt8((i * 91 + 11) % 256)
            pixels[i * 4 + 2] = UInt8((i * 5 + 200) % 256)
            pixels[i * 4 + 3] = UInt8((i * 17 + 3) % 256)
        }
        let roundTripImg = PNGImage(width: 3, height: 5, pixels: pixels)
        if let encoded = try? PNG.encode(roundTripImg), let decoded = try? PNG.decode(encoded) {
            h.eq("png: encode->decode round trip is byte-exact", decoded.pixels, pixels)
        } else {
            h.check("png: encode->decode round trip is byte-exact", false)
        }
    }

    private static func throwsPNG(_ bytes: [UInt8]) -> Bool {
        do { _ = try PNG.decode(bytes); return false }
        catch { return true }
    }

    // ---- PNG fixture builders --------------------------------------------------

    private static func buildPNG(width: Int, height: Int, colorType: Int, raw: [UInt8],
                                 extraChunks: [(String, [UInt8])] = []) -> [UInt8] {
        var out = pngSignatureAndIHDR(width: width, height: height, colorType: colorType)
        for (type, data) in extraChunks {
            out.append(contentsOf: pngChunk(type, data))
        }
        out.append(contentsOf: pngChunk("IDAT", zlibStoredWrap(raw)))
        out.append(contentsOf: pngChunk("IEND", []))
        return out
    }

    private static func pngSignatureAndIHDR(width: Int, height: Int, colorType: Int, bitDepth: UInt8 = 8, interlace: UInt8 = 0) -> [UInt8] {
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var ihdr: [UInt8] = []
        appendU32BE(&ihdr, UInt32(width))
        appendU32BE(&ihdr, UInt32(height))
        ihdr.append(contentsOf: [bitDepth, UInt8(colorType), 0, 0, interlace])
        out.append(contentsOf: pngChunk("IHDR", ihdr))
        return out
    }

    private static func pngChunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        appendU32BE(&out, UInt32(data.count))
        let typeBytes = Array(type.utf8)
        out.append(contentsOf: typeBytes)
        out.append(contentsOf: data)
        appendU32BE(&out, CRC32.of(typeBytes, data))
        return out
    }

    private static func appendU32BE(_ out: inout [UInt8], _ v: UInt32) {
        out.append(UInt8((v >> 24) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8(v & 0xFF))
    }

    // =========================================================================
    // MARK: - ZIP
    // =========================================================================

    private static func runZipChecks(_ h: inout SmokeHarness) {
        // ---- stored entry -----------------------------------------------------
        let storedContent = Array("hello zip".utf8)
        let storedZip = buildZip(entries: [("hello.txt", storedContent, false)])
        if let reader = try? ZipReader(Data(storedZip)) {
            h.check("zip: stored entry listed", reader.entries["hello.txt"] != nil)
            if let data = try? reader.extract("hello.txt") {
                h.eq("zip: stored entry content", [UInt8](data), storedContent)
            } else {
                h.check("zip: stored entry content", false)
            }
        } else {
            h.check("zip: stored entry listed", false)
            h.check("zip: stored entry content", false)
        }

        // ---- deflated entry -----------------------------------------------------
        let deflatedContent = Array("AABB".utf8) // 'A','A','B','B'
        let deflatedZip = buildZip(entries: [("data.bin", deflatedContent, true)])
        if let reader = try? ZipReader(Data(deflatedZip)) {
            if let data = try? reader.extract("data.bin") {
                h.eq("zip: deflated entry content", [UInt8](data), deflatedContent)
            } else {
                h.check("zip: deflated entry content", false)
            }
        } else {
            h.check("zip: deflated entry content", false)
        }

        // ---- EOCD with a comment -------------------------------------------------
        var withComment = buildZip(entries: [("a.txt", Array("x".utf8), false)])
        let comment = Array("hello from the comment field".utf8)
        // the archive already ends with a (commentLen=0) EOCD; append the comment
        // bytes and patch the 2-byte comment-length field near its tail
        let eocdCommentLenOffset = withComment.count - 2
        withComment[eocdCommentLenOffset] = UInt8(comment.count & 0xFF)
        withComment[eocdCommentLenOffset + 1] = UInt8((comment.count >> 8) & 0xFF)
        withComment.append(contentsOf: comment)
        if let reader = try? ZipReader(Data(withComment)) {
            h.check("zip: EOCD with comment still parses", reader.entries["a.txt"] != nil)
        } else {
            h.check("zip: EOCD with comment still parses", false)
        }

        // ---- path traversal rejected ---------------------------------------------
        let traversalZip = buildZip(entries: [("../evil.txt", Array("x".utf8), false)])
        h.check("zip: path traversal rejected", throwsZip(traversalZip))

        // ---- absolute path rejected ------------------------------------------------
        let absoluteZip = buildZip(entries: [("/etc/passwd", Array("x".utf8), false)])
        h.check("zip: absolute path rejected", throwsZip(absoluteZip))

        // ---- zip-bomb ratio rejected -----------------------------------------------
        // central directory claims 10 compressed bytes expand to 10,000,000 —
        // metadata-only check, no need for the local entry to actually be valid
        let bombZip = buildZipRaw(name: "bomb.bin", method: 8, compSize: 10, uncompSize: 10_000_000, crc: 0, localData: [UInt8](repeating: 0, count: 10))
        h.check("zip: zip-bomb ratio rejected", throwsZip(bombZip))

        // ---- CRC mismatch rejected ---------------------------------------------------
        let crcContent = Array("correct bytes".utf8)
        var crcZip = buildZip(entries: [("f.bin", crcContent, false)])
        // corrupt just the central-directory CRC field (offset 16 within the central
        // record) for the single entry, without touching path/method/sizes
        if let cdOffset = findCentralDirectoryRecord(crcZip) {
            crcZip[cdOffset + 16] ^= 0xFF
        }
        if let reader = try? ZipReader(Data(crcZip)) {
            h.check("zip: CRC mismatch rejected", throwsZipExtract(reader, "f.bin"))
        } else {
            h.check("zip: CRC mismatch rejected", false)
        }

        // ---- Zip64 rejected -----------------------------------------------------------
        var zip64 = buildZip(entries: [("a.txt", Array("x".utf8), false)])
        // sentinel: EOCD's total-entries field (offset 10 within the 22-byte EOCD record) = 0xFFFF
        let eocdOffset = zip64.count - 22
        zip64[eocdOffset + 10] = 0xFF
        zip64[eocdOffset + 11] = 0xFF
        h.check("zip: Zip64 EOCD sentinel rejected", throwsZip(zip64))

        // ---- truncated archive rejected -----------------------------------------------
        h.check("zip: truncated archive (too short) rejected", throwsZip([0x50, 0x4B, 0x03, 0x04]))
        h.check("zip: truncated archive (no EOCD) rejected", throwsZip([UInt8](repeating: 0, count: 40)))
    }

    private static func throwsZip(_ bytes: [UInt8]) -> Bool {
        do { _ = try ZipReader(Data(bytes)); return false }
        catch { return true }
    }

    private static func throwsZipExtract(_ reader: ZipReader, _ name: String) -> Bool {
        do { _ = try reader.extract(name); return false }
        catch { return true }
    }

    /// finds the offset of the single central-directory record's signature in a
    /// buildZip()-produced archive with exactly one entry
    private static func findCentralDirectoryRecord(_ bytes: [UInt8]) -> Int? {
        var i = 0
        while i + 4 <= bytes.count {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x01, bytes[i + 3] == 0x02 { return i }
            i += 1
        }
        return nil
    }

    // ---- ZIP fixture builder ----------------------------------------------------

    /// builds a minimal valid ZIP: local headers + data, central directory, EOCD.
    /// `deflate: true` compresses via a fixed-Huffman DEFLATE block (real, decodable
    /// compression, not just a stored passthrough) so the deflate path is genuinely exercised.
    private static func buildZip(entries: [(name: String, content: [UInt8], deflate: Bool)]) -> [UInt8] {
        var out: [UInt8] = []
        var centralDirectory: [UInt8] = []
        var localOffsets: [Int] = []

        for e in entries {
            localOffsets.append(out.count)
            let nameBytes = Array(e.name.utf8)
            let crc = CRC32.of(e.content)
            let stored: [UInt8]
            let method: UInt16
            if e.deflate {
                stored = deflateFixedHuffman(e.content)
                method = 8
            } else {
                stored = e.content
                method = 0
            }

            var local: [UInt8] = []
            appendU32LE(&local, 0x04034b50)
            appendU16LE(&local, 20)          // version needed
            appendU16LE(&local, 0)           // flags
            appendU16LE(&local, method)
            appendU16LE(&local, 0)           // mod time
            appendU16LE(&local, 0)           // mod date
            appendU32LE(&local, crc)
            appendU32LE(&local, UInt32(stored.count))
            appendU32LE(&local, UInt32(e.content.count))
            appendU16LE(&local, UInt16(nameBytes.count))
            appendU16LE(&local, 0)           // extra length
            local.append(contentsOf: nameBytes)
            local.append(contentsOf: stored)
            out.append(contentsOf: local)

            var central: [UInt8] = []
            appendU32LE(&central, 0x02014b50)
            appendU16LE(&central, 20)        // version made by
            appendU16LE(&central, 20)        // version needed
            appendU16LE(&central, 0)         // flags
            appendU16LE(&central, method)
            appendU16LE(&central, 0)         // mod time
            appendU16LE(&central, 0)         // mod date
            appendU32LE(&central, crc)
            appendU32LE(&central, UInt32(stored.count))
            appendU32LE(&central, UInt32(e.content.count))
            appendU16LE(&central, UInt16(nameBytes.count))
            appendU16LE(&central, 0)         // extra length
            appendU16LE(&central, 0)         // comment length
            appendU16LE(&central, 0)         // disk number start
            appendU16LE(&central, 0)         // internal attrs
            appendU32LE(&central, 0)         // external attrs
            appendU32LE(&central, UInt32(localOffsets.last!))
            central.append(contentsOf: nameBytes)
            centralDirectory.append(contentsOf: central)
        }

        let cdOffset = out.count
        out.append(contentsOf: centralDirectory)

        var eocd: [UInt8] = []
        appendU32LE(&eocd, 0x06054b50)
        appendU16LE(&eocd, 0)                  // disk number
        appendU16LE(&eocd, 0)                  // disk with CD
        appendU16LE(&eocd, UInt16(entries.count))
        appendU16LE(&eocd, UInt16(entries.count))
        appendU32LE(&eocd, UInt32(centralDirectory.count))
        appendU32LE(&eocd, UInt32(cdOffset))
        appendU16LE(&eocd, 0)                  // comment length
        out.append(contentsOf: eocd)
        return out
    }

    /// builds a ZIP with exactly one entry whose central-directory metadata is
    /// specified directly — used for the zip-bomb test, where the claimed sizes
    /// don't need to correspond to real compressed data.
    private static func buildZipRaw(name: String, method: UInt16, compSize: Int, uncompSize: Int, crc: UInt32, localData: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        let nameBytes = Array(name.utf8)
        let localOffset = 0

        var local: [UInt8] = []
        appendU32LE(&local, 0x04034b50)
        appendU16LE(&local, 20)
        appendU16LE(&local, 0)
        appendU16LE(&local, method)
        appendU16LE(&local, 0)
        appendU16LE(&local, 0)
        appendU32LE(&local, crc)
        appendU32LE(&local, UInt32(compSize))
        appendU32LE(&local, UInt32(uncompSize))
        appendU16LE(&local, UInt16(nameBytes.count))
        appendU16LE(&local, 0)
        local.append(contentsOf: nameBytes)
        local.append(contentsOf: localData)
        out.append(contentsOf: local)

        let cdOffset = out.count
        var central: [UInt8] = []
        appendU32LE(&central, 0x02014b50)
        appendU16LE(&central, 20)
        appendU16LE(&central, 20)
        appendU16LE(&central, 0)
        appendU16LE(&central, method)
        appendU16LE(&central, 0)
        appendU16LE(&central, 0)
        appendU32LE(&central, crc)
        appendU32LE(&central, UInt32(compSize))
        appendU32LE(&central, UInt32(uncompSize))
        appendU16LE(&central, UInt16(nameBytes.count))
        appendU16LE(&central, 0)
        appendU16LE(&central, 0)
        appendU16LE(&central, 0)
        appendU16LE(&central, 0)
        appendU32LE(&central, 0)
        appendU32LE(&central, UInt32(localOffset))
        central.append(contentsOf: nameBytes)
        out.append(contentsOf: central)

        var eocd: [UInt8] = []
        appendU32LE(&eocd, 0x06054b50)
        appendU16LE(&eocd, 0)
        appendU16LE(&eocd, 0)
        appendU16LE(&eocd, 1)
        appendU16LE(&eocd, 1)
        appendU32LE(&eocd, UInt32(central.count))
        appendU32LE(&eocd, UInt32(cdOffset))
        appendU16LE(&eocd, 0)
        out.append(contentsOf: eocd)
        return out
    }

    private static func appendU16LE(_ out: inout [UInt8], _ v: UInt16) {
        out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
    }

    private static func appendU32LE(_ out: inout [UInt8], _ v: UInt32) {
        out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8((v >> 24) & 0xFF))
    }

    /// compresses arbitrary bytes as one fixed-Huffman DEFLATE block (literals only,
    /// no back-references) — enough to exercise the real Inflate deflate-method-8 path.
    private static func deflateFixedHuffman(_ bytes: [UInt8]) -> [UInt8] {
        var w = TestBitWriter()
        w.writeBit(1)
        w.writeBitsLSBFirst(1, 2)
        for b in bytes { w.writeSymbol(fixedLitTable, Int(b)) }
        w.writeSymbol(fixedLitTable, 256)
        return w.finished()
    }
}

// =============================================================================
// MARK: - bit-level DEFLATE test fixture builder
//
// Independent of PebbleCodecs' own encoder: a minimal MSB-first-Huffman /
// LSB-first-field bit writer, used only to hand-construct exact DEFLATE
// streams for the Inflate tests above (fixed and dynamic Huffman blocks,
// a bad-block-type header, an out-of-range back-reference).
// =============================================================================

private struct TestBitWriter {
    private var bytes: [UInt8] = []
    private var cur: UInt8 = 0
    private var bitPos = 0

    mutating func writeBit(_ b: Int) {
        if b != 0 { cur |= (1 << bitPos) }
        bitPos += 1
        if bitPos == 8 { bytes.append(cur); cur = 0; bitPos = 0 }
    }

    /// regular (non-Huffman) integer field: packed LSB-first
    mutating func writeBitsLSBFirst(_ value: Int, _ n: Int) {
        for i in 0..<n { writeBit((value >> i) & 1) }
    }

    /// a canonical Huffman code of `len` bits: packed MSB-first
    mutating func writeHuffmanCode(_ code: Int, _ len: Int) {
        var i = len - 1
        while i >= 0 { writeBit((code >> i) & 1); i -= 1 }
    }

    mutating func writeSymbol(_ table: CanonicalTable, _ symbol: Int) {
        writeHuffmanCode(table.codes[symbol], table.lengths[symbol])
    }

    func finished() -> [UInt8] {
        var out = bytes
        if bitPos != 0 { out.append(cur) }
        return out
    }
}

/// symbol -> (canonical code, code length), built via the standard RFC 1951
/// 3.2.2 canonical-code assignment from a code-length-per-symbol array.
private struct CanonicalTable {
    let lengths: [Int]
    let codes: [Int]

    init(lengths: [Int]) {
        self.lengths = lengths
        let maxBits = max(lengths.max() ?? 0, 1)
        var blCount = [Int](repeating: 0, count: maxBits + 1)
        for l in lengths where l > 0 { blCount[l] += 1 }
        var code = 0
        var nextCode = [Int](repeating: 0, count: maxBits + 1)
        for bits in 1...maxBits {
            code = (code + blCount[bits - 1]) << 1
            nextCode[bits] = code
        }
        var codes = [Int](repeating: 0, count: lengths.count)
        for (n, len) in lengths.enumerated() where len > 0 {
            codes[n] = nextCode[len]
            nextCode[len] += 1
        }
        self.codes = codes
    }
}

/// RFC 1951 3.2.6 fixed Huffman code-length profiles
private let fixedLitTable = CanonicalTable(lengths:
    [Int](repeating: 8, count: 144) + [Int](repeating: 9, count: 112)
    + [Int](repeating: 7, count: 24) + [Int](repeating: 8, count: 8))
private let fixedDistTable = CanonicalTable(lengths: [Int](repeating: 5, count: 30))

private let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

/// builds one complete, spec-valid dynamic-Huffman DEFLATE block: a lit/length
/// alphabet with exactly two used symbols (the given literal and end-of-block,
/// each a 1-bit code) and an empty distance table (no back-references), per
/// RFC 1951 3.2.7 — "no distance codes used at all" is legal when every length
/// in the transmitted table is 0.
private func buildMinimalDynamicBlock(literal: Int) -> [UInt8] {
    // lit/length code lengths: 257 entries (0...256), only `literal` and 256 (EOB) set to 1
    var litLengths = [Int](repeating: 0, count: 257)
    litLengths[literal] = 1
    litLengths[256] = 1
    let distLengths = [0]   // HDIST=1, single length-0 entry: no distance codes used

    // code-length alphabet: only symbols "0" and "1" appear in the sequence below,
    // each given a 1-bit code
    var clLengths = [Int](repeating: 0, count: 19)
    clLengths[0] = 1
    clLengths[1] = 1
    let clTable = CanonicalTable(lengths: clLengths)

    // HCLEN must cover the order-position of the highest-index code-length symbol
    // we actually use (symbol "1" sits at codeLengthOrder position 17)
    let hclenCount = 18
    var orderedCL = [Int](repeating: 0, count: hclenCount)
    for i in 0..<hclenCount { orderedCL[i] = clLengths[codeLengthOrder[i]] }

    var w = TestBitWriter()
    w.writeBit(1)                                  // BFINAL=1
    w.writeBitsLSBFirst(2, 2)                       // BTYPE=10 (dynamic)
    w.writeBitsLSBFirst(litLengths.count - 257, 5)  // HLIT=0 -> 257 lit/length codes
    w.writeBitsLSBFirst(distLengths.count - 1, 5)   // HDIST=0 -> 1 distance code
    w.writeBitsLSBFirst(hclenCount - 4, 4)          // HCLEN=14 -> 18 code-length entries
    for v in orderedCL { w.writeBitsLSBFirst(v, 3) }

    // transmit the lit/length + distance code lengths themselves, each Huffman-coded
    // via the code-length alphabet (no run-length codes needed: only 0s and 1s)
    for len in litLengths { w.writeSymbol(clTable, len) }
    for len in distLengths { w.writeSymbol(clTable, len) }

    // the actual compressed data: one literal, then end-of-block, coded with the
    // now-fully-specified lit/length table
    let dataTable = CanonicalTable(lengths: litLengths)
    w.writeSymbol(dataTable, literal)
    w.writeSymbol(dataTable, 256)

    return w.finished()
}
