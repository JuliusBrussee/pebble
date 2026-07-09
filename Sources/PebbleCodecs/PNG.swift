// Portable PNG decoder/encoder — no ImageIO/CoreGraphics. Decodes 8-bit
// grayscale/gray+alpha/RGB/RGBA and palette (PLTE+tRNS), all 5 filter types,
// non-interlaced only. 16-bit and Adam7-interlaced PNGs are explicitly
// rejected (thrown), never silently mis-decoded.
//
// PNGImage.pixels is straight (non-premultiplied) RGBA8, row-major, top-left
// origin, 4 bytes/pixel — the same shape as Pebble's app-layer RGBAImage, so
// a caller can wrap/convert directly.
//
// The encoder writes 8-bit RGBA with filter type 0 (None) and stored (no
// compression) DEFLATE blocks — valid, spec-conformant PNG, just not a small
// one. decode(encode(img)) round-trips byte-exact.

import Foundation

public struct PNGImage {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]   // width*height*4, straight RGBA8

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

public enum PNGError: Error, Equatable {
    case badSignature
    case truncated
    case badChunkCRC
    case missingIHDR
    case badDimensions
    case unsupportedBitDepth
    case unsupportedColorType
    case unsupportedInterlace
    case unsupportedCompressionOrFilterMethod
    case dimensionsTooLarge
    case missingPalette
    case paletteIndexOutOfRange
    case missingIDAT
    case rawDataSizeMismatch
    case badFilterType
}

public enum PNG {
    /// caller cap on the decoded RGBA8 buffer (width*height*4); default 64MB (16M pixels)
    public static let defaultMaxPixelBytes = 64 << 20

    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public static func decode(_ data: Data, maxPixelBytes: Int = PNG.defaultMaxPixelBytes) throws -> PNGImage {
        let bytes = [UInt8](data)
        return try decode(bytes, maxPixelBytes: maxPixelBytes)
    }

    public static func decode(_ bytes: [UInt8], maxPixelBytes: Int = PNG.defaultMaxPixelBytes) throws -> PNGImage {
        guard bytes.count >= 8, Array(bytes[0..<8]) == signature else { throw PNGError.badSignature }

        var width = 0, height = 0, colorType = 0
        var palette: [UInt8] = []   // RGB triples, flattened
        var trns: [UInt8] = []
        var idat: [UInt8] = []
        var sawIHDR = false
        var sawIEND = false

        var pos = 8
        while pos < bytes.count {
            guard pos + 8 <= bytes.count else { throw PNGError.truncated }
            let len = Int(readU32BE(bytes, pos))
            let typeStart = pos + 4
            let dataStart = typeStart + 4
            guard dataStart <= bytes.count, len <= bytes.count - dataStart else { throw PNGError.truncated }
            let dataEnd = dataStart + len
            guard dataEnd + 4 <= bytes.count else { throw PNGError.truncated }

            let typeBytes = Array(bytes[typeStart..<dataStart])
            let chunkData = Array(bytes[dataStart..<dataEnd])
            let crcField = readU32BE(bytes, dataEnd)
            guard CRC32.of(typeBytes, chunkData) == crcField else { throw PNGError.badChunkCRC }
            let type = String(decoding: typeBytes, as: UTF8.self)

            switch type {
            case "IHDR":
                guard !sawIHDR, chunkData.count == 13 else { throw PNGError.badDimensions }
                width = Int(readU32BE(chunkData, 0))
                height = Int(readU32BE(chunkData, 4))
                let bitDepth = Int(chunkData[8])
                colorType = Int(chunkData[9])
                let compressionMethod = chunkData[10]
                let filterMethod = chunkData[11]
                let interlace = chunkData[12]
                guard width > 0, height > 0 else { throw PNGError.badDimensions }
                guard bitDepth == 8 else { throw PNGError.unsupportedBitDepth }
                guard [0, 2, 3, 4, 6].contains(colorType) else { throw PNGError.unsupportedColorType }
                guard compressionMethod == 0, filterMethod == 0 else { throw PNGError.unsupportedCompressionOrFilterMethod }
                guard interlace == 0 else { throw PNGError.unsupportedInterlace }
                let (pixelCount, overflowA) = width.multipliedReportingOverflow(by: height)
                guard !overflowA else { throw PNGError.dimensionsTooLarge }
                let (totalBytes, overflowB) = pixelCount.multipliedReportingOverflow(by: 4)
                guard !overflowB, totalBytes <= maxPixelBytes else { throw PNGError.dimensionsTooLarge }
                sawIHDR = true
            case "PLTE":
                guard sawIHDR else { throw PNGError.missingIHDR }
                guard chunkData.count % 3 == 0, chunkData.count / 3 <= 256 else { throw PNGError.badDimensions }
                palette = chunkData
            case "tRNS":
                guard sawIHDR else { throw PNGError.missingIHDR }
                trns = chunkData
            case "IDAT":
                guard sawIHDR else { throw PNGError.missingIHDR }
                idat.append(contentsOf: chunkData)
            case "IEND":
                sawIEND = true
            default:
                break // ancillary chunk, ignore
            }

            pos = dataEnd + 4
            if sawIEND { break }
        }

        guard sawIHDR else { throw PNGError.missingIHDR }
        guard sawIEND else { throw PNGError.truncated }
        guard !idat.isEmpty else { throw PNGError.missingIDAT }
        if colorType == 3 && palette.isEmpty { throw PNGError.missingPalette }

        let bpp: Int   // bytes per pixel in the raw (post-inflate, pre-unfilter) scanlines
        switch colorType {
        case 0: bpp = 1
        case 2: bpp = 3
        case 3: bpp = 1
        case 4: bpp = 2
        case 6: bpp = 4
        default: throw PNGError.unsupportedColorType
        }
        let rowBytes = width * bpp
        let (expectedRawSize, overflowC) = (rowBytes + 1).multipliedReportingOverflow(by: height)
        guard !overflowC else { throw PNGError.dimensionsTooLarge }

        let raw = try Zlib.inflate(idat, maxOutputBytes: expectedRawSize)
        guard raw.count == expectedRawSize else { throw PNGError.rawDataSizeMismatch }

        var recon = [UInt8](repeating: 0, count: rowBytes * height)
        var srcPos = 0
        for row in 0..<height {
            let filterType = raw[srcPos]
            srcPos += 1
            let rowStart = row * rowBytes
            let prevRowStart = rowStart - rowBytes
            for x in 0..<rowBytes {
                let filt = raw[srcPos + x]
                let a = x >= bpp ? recon[rowStart + x - bpp] : 0
                let b = row > 0 ? recon[prevRowStart + x] : 0
                let c = (row > 0 && x >= bpp) ? recon[prevRowStart + x - bpp] : 0
                let pred: UInt8
                switch filterType {
                case 0: pred = 0
                case 1: pred = a
                case 2: pred = b
                case 3: pred = UInt8((Int(a) + Int(b)) / 2)
                case 4: pred = paeth(a, b, c)
                default: throw PNGError.badFilterType
                }
                recon[rowStart + x] = filt &+ pred
            }
            srcPos += rowBytes
        }

        var out = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let rowStart = row * rowBytes
            let outRowStart = row * width * 4
            for xPix in 0..<width {
                let si = rowStart + xPix * bpp
                let di = outRowStart + xPix * 4
                switch colorType {
                case 0:
                    let g = recon[si]
                    out[di] = g; out[di + 1] = g; out[di + 2] = g
                    out[di + 3] = isGrayKeyTransparent(g, trns) ? 0 : 255
                case 2:
                    let r = recon[si], g = recon[si + 1], b = recon[si + 2]
                    out[di] = r; out[di + 1] = g; out[di + 2] = b
                    out[di + 3] = isRGBKeyTransparent(r, g, b, trns) ? 0 : 255
                case 3:
                    let idx = Int(recon[si])
                    guard idx * 3 + 2 < palette.count else { throw PNGError.paletteIndexOutOfRange }
                    out[di] = palette[idx * 3]; out[di + 1] = palette[idx * 3 + 1]; out[di + 2] = palette[idx * 3 + 2]
                    out[di + 3] = idx < trns.count ? trns[idx] : 255
                case 4:
                    let g = recon[si], a = recon[si + 1]
                    out[di] = g; out[di + 1] = g; out[di + 2] = g; out[di + 3] = a
                case 6:
                    out[di] = recon[si]; out[di + 1] = recon[si + 1]; out[di + 2] = recon[si + 2]; out[di + 3] = recon[si + 3]
                default:
                    break
                }
            }
        }
        return PNGImage(width: width, height: height, pixels: out)
    }

    // ---- encode: 8-bit RGBA, filter 0, stored deflate ------------------------

    public static func encode(_ img: PNGImage) throws -> Data {
        Data(try encodeBytes(img))
    }

    public static func encodeBytes(_ img: PNGImage) throws -> [UInt8] {
        guard img.width > 0, img.height > 0, img.pixels.count == img.width * img.height * 4 else { throw PNGError.badDimensions }

        var raw = [UInt8]()
        raw.reserveCapacity(img.height * (1 + img.width * 4))
        for row in 0..<img.height {
            raw.append(0) // filter type 0 (None)
            let start = row * img.width * 4
            raw.append(contentsOf: img.pixels[start..<(start + img.width * 4)])
        }

        var zlibBytes: [UInt8] = [0x78, 0x01]   // CMF=deflate/32K window, FLG=fastest, valid FCHECK
        zlibBytes.append(contentsOf: deflateStored(raw))
        let adler = Adler32.checksum(raw)
        zlibBytes.append(UInt8((adler >> 24) & 0xFF))
        zlibBytes.append(UInt8((adler >> 16) & 0xFF))
        zlibBytes.append(UInt8((adler >> 8) & 0xFF))
        zlibBytes.append(UInt8(adler & 0xFF))

        var ihdr = [UInt8]()
        appendU32BE(&ihdr, UInt32(img.width))
        appendU32BE(&ihdr, UInt32(img.height))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0])   // bitDepth=8, colorType=6 (RGBA), comp/filter/interlace=0

        var out = signature
        out.append(contentsOf: chunk("IHDR", ihdr))
        out.append(contentsOf: chunk("IDAT", zlibBytes))
        out.append(contentsOf: chunk("IEND", []))
        return out
    }

    /// wrap raw bytes in DEFLATE stored (uncompressed) blocks — no Huffman coding
    /// needed since "stored-or-fixed deflate is fine" for our encoder
    private static func deflateStored(_ raw: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        if raw.isEmpty {
            out.append(1) // BFINAL=1, BTYPE=00, byte-aligned already
            out.append(contentsOf: [0, 0, 0xFF, 0xFF])
            return out
        }
        var offset = 0
        while offset < raw.count {
            let chunkLen = min(65535, raw.count - offset)
            let isFinal = offset + chunkLen == raw.count
            out.append(isFinal ? 1 : 0)
            let len = UInt16(chunkLen)
            let nlen = ~len
            out.append(UInt8(len & 0xFF)); out.append(UInt8(len >> 8))
            out.append(UInt8(nlen & 0xFF)); out.append(UInt8(nlen >> 8))
            out.append(contentsOf: raw[offset..<(offset + chunkLen)])
            offset += chunkLen
        }
        return out
    }

    private static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        appendU32BE(&out, UInt32(data.count))
        let typeBytes = Array(type.utf8)
        out.append(contentsOf: typeBytes)
        out.append(contentsOf: data)
        let crc = CRC32.of(typeBytes, data)
        appendU32BE(&out, crc)
        return out
    }

    // ---- helpers --------------------------------------------------------------

    private static func readU32BE(_ bytes: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(bytes[o]) << 24) | (UInt32(bytes[o + 1]) << 16) | (UInt32(bytes[o + 2]) << 8) | UInt32(bytes[o + 3])
    }

    private static func appendU32BE(_ out: inout [UInt8], _ v: UInt32) {
        out.append(UInt8((v >> 24) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8(v & 0xFF))
    }

    private static func paeth(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
        let ai = Int(a), bi = Int(b), ci = Int(c)
        let p = ai + bi - ci
        let pa = abs(p - ai), pb = abs(p - bi), pc = abs(p - ci)
        if pa <= pb && pa <= pc { return a }
        if pb <= pc { return b }
        return c
    }

    private static func isGrayKeyTransparent(_ g: UInt8, _ trns: [UInt8]) -> Bool {
        guard trns.count >= 2 else { return false }
        let key = (Int(trns[0]) << 8) | Int(trns[1])
        return Int(g) == key
    }

    private static func isRGBKeyTransparent(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ trns: [UInt8]) -> Bool {
        guard trns.count >= 6 else { return false }
        let kr = (Int(trns[0]) << 8) | Int(trns[1])
        let kg = (Int(trns[2]) << 8) | Int(trns[3])
        let kb = (Int(trns[4]) << 8) | Int(trns[5])
        return Int(r) == kr && Int(g) == kg && Int(b) == kb
    }
}
