// Read-only ZIP reader for resource packs — no Compression/zlib linkage.
// Parses the End-Of-Central-Directory (scanning back through a trailing
// comment), the central directory, and local headers on demand. Supports
// stored (method 0) and deflate (method 8) entries.
//
// Security: path safety (absolute paths, ".." traversal, backslash
// separators) and size caps are enforced when the central directory is
// parsed, so a malicious entry poisons the whole archive rather than being
// silently skipped. CRC-32 is verified on every extract(). Zip64 (EOCD
// locator/record, or any 0xFFFF/0xFFFFFFFF sentinel in the EOCD) is rejected
// outright rather than parsed. Never traps: every offset is bounds-checked.

import Foundation

public enum ZipError: Error, Equatable {
    case notAZip
    case zip64Unsupported
    case truncated
    case badLocalHeader
    case absolutePath
    case pathTraversal
    case backslashSeparator
    case entryTooLarge
    case zipBombSuspected
    case crcMismatch
    case unsupportedMethod
    case entryNotFound
}

public final class ZipReader {
    public struct Entry {
        public let name: String
        public let method: UInt16
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let crc32: UInt32
        fileprivate let localHeaderOffset: Int
    }

    public static let defaultMaxEntryUncompressedBytes = 64 << 20   // 64MB, matches the app's resource-pack cap
    private static let bombRatio = 200
    private static let bombFloorBytes = 1 << 20   // below this, even a large ratio is not treated as a bomb

    public private(set) var entries: [String: Entry] = [:]
    private let data: [UInt8]

    public init(_ archiveData: Data, maxEntryUncompressedBytes: Int = ZipReader.defaultMaxEntryUncompressedBytes) throws {
        let bytes = [UInt8](archiveData)
        self.data = bytes
        self.entries = try ZipReader.parseCentralDirectory(bytes, maxEntryUncompressedBytes: maxEntryUncompressedBytes)
    }

    /// decompressed bytes for a listed entry, CRC-32 verified against the central directory record
    public func extract(_ name: String) throws -> Data {
        guard let e = entries[name] else { throw ZipError.entryNotFound }
        let lo = e.localHeaderOffset
        guard lo >= 0, lo + 30 <= data.count else { throw ZipError.truncated }
        guard readU32Unchecked(data, lo) == 0x04034b50 else { throw ZipError.badLocalHeader }
        guard let nameLen = Self.readU16(data, lo + 26), let extraLen = Self.readU16(data, lo + 28) else { throw ZipError.truncated }
        let start = lo + 30 + nameLen + extraLen
        guard start >= 0, start <= data.count, e.compressedSize <= data.count - start else { throw ZipError.truncated }
        let raw = Array(data[start..<(start + e.compressedSize)])

        let decompressed: [UInt8]
        switch e.method {
        case 0:
            guard raw.count == e.uncompressedSize else { throw ZipError.badLocalHeader }
            decompressed = raw
        case 8:
            decompressed = try Inflate.inflate(raw, maxOutputBytes: e.uncompressedSize)
            guard decompressed.count == e.uncompressedSize else { throw ZipError.badLocalHeader }
        default:
            throw ZipError.unsupportedMethod
        }

        guard CRC32.of(decompressed) == e.crc32 else { throw ZipError.crcMismatch }
        return Data(decompressed)
    }

    // ---- central directory parse ---------------------------------------------

    private static func parseCentralDirectory(_ data: [UInt8], maxEntryUncompressedBytes: Int) throws -> [String: Entry] {
        let n = data.count
        guard n >= 22 else { throw ZipError.truncated }

        // EOCD signature, scanning back from the tail (comment can pad up to 64KB)
        var eocd = -1
        let commentMax = min(65535, n - 22)
        var i = n - 22
        let stop = n - 22 - commentMax
        while i >= stop {
            if data[i] == 0x50, data[i + 1] == 0x4b, data[i + 2] == 0x05, data[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }

        // a Zip64 EOCD locator, if present, sits exactly 20 bytes before the EOCD record
        if eocd >= 20, readU32(data, eocd - 20) == 0x07064b50 {
            throw ZipError.zip64Unsupported
        }

        guard let numEntries = readU16(data, eocd + 10),
              let cdSizeU32 = readU32(data, eocd + 12),
              let cdOffsetU32 = readU32(data, eocd + 16) else { throw ZipError.truncated }
        guard numEntries != 0xFFFF, cdSizeU32 != 0xFFFFFFFF, cdOffsetU32 != 0xFFFFFFFF else { throw ZipError.zip64Unsupported }

        let cdOffset = Int(cdOffsetU32)
        guard cdOffset >= 0, cdOffset <= n else { throw ZipError.truncated }

        var entries: [String: Entry] = [:]
        var off = cdOffset
        for _ in 0..<numEntries {
            guard off + 46 <= n else { throw ZipError.truncated }
            guard readU32(data, off) == 0x02014b50 else { throw ZipError.badLocalHeader }
            guard let method = readU16(data, off + 10),
                  let crc = readU32(data, off + 16),
                  let compSizeU32 = readU32(data, off + 20),
                  let uncompSizeU32 = readU32(data, off + 24),
                  let nameLen = readU16(data, off + 28),
                  let extraLen = readU16(data, off + 30),
                  let commentLen = readU16(data, off + 32),
                  let localOffsetU32 = readU32(data, off + 42) else { throw ZipError.truncated }
            guard off + 46 + nameLen <= n else { throw ZipError.truncated }

            let nameBytes = Array(data[(off + 46)..<(off + 46 + nameLen)])
            guard let name = String(bytes: nameBytes, encoding: .utf8) else { throw ZipError.badLocalHeader }

            if !name.hasSuffix("/") {
                try validatePath(name)
                let compSize = Int(compSizeU32), uncompSize = Int(uncompSizeU32)
                guard uncompSize <= maxEntryUncompressedBytes else { throw ZipError.entryTooLarge }
                if uncompSize > bombFloorBytes {
                    // zip-bomb heuristic: only flags large AND disproportionate expansion —
                    // tiny highly-compressible files are normal and must not trip this.
                    if compSize == 0 || uncompSize > compSize * bombRatio {
                        throw ZipError.zipBombSuspected
                    }
                }
                entries[name] = Entry(name: name, method: UInt16(method), compressedSize: compSize,
                                      uncompressedSize: uncompSize, crc32: crc, localHeaderOffset: Int(localOffsetU32))
            }
            off += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    private static func validatePath(_ name: String) throws {
        guard !name.hasPrefix("/") else { throw ZipError.absolutePath }
        guard !name.contains("\\") else { throw ZipError.backslashSeparator }
        let chars = Array(name)
        if chars.count >= 2, chars[1] == ":" { throw ZipError.absolutePath }   // "C:..." drive-letter absolute path
        let comps = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !comps.contains("..") else { throw ZipError.pathTraversal }
    }

    // ---- bounds-checked little-endian reads (never trap) ----------------------

    private static func readU16(_ data: [UInt8], _ o: Int) -> Int? {
        guard o >= 0, o + 2 <= data.count else { return nil }
        return Int(data[o]) | (Int(data[o + 1]) << 8)
    }

    private static func readU32(_ data: [UInt8], _ o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= data.count else { return nil }
        return UInt32(data[o]) | (UInt32(data[o + 1]) << 8) | (UInt32(data[o + 2]) << 16) | (UInt32(data[o + 3]) << 24)
    }
}

/// non-throwing convenience for call sites that already bounds-checked (extract())
private func readU32Unchecked(_ data: [UInt8], _ o: Int) -> UInt32 {
    UInt32(data[o]) | (UInt32(data[o + 1]) << 8) | (UInt32(data[o + 2]) << 16) | (UInt32(data[o + 3]) << 24)
}
