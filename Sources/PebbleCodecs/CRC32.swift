// CRC-32 (IEEE 802.3 / ISO-HDLC, polynomial 0xEDB88320) — used by PNG chunk
// checksums and ZIP entries. Pure Swift, table-based, no zlib/Compression.

public enum CRC32 {
    private static let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            t[i] = c
        }
        return t
    }()

    /// crc32 of a single buffer
    public static func of(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in bytes {
            crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    /// crc32 over two buffers as if concatenated — avoids an allocation for
    /// PNG's "type bytes + chunk data" checksum
    public static func of(_ a: [UInt8], _ b: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for x in a { crc = table[Int((crc ^ UInt32(x)) & 0xFF)] ^ (crc >> 8) }
        for x in b { crc = table[Int((crc ^ UInt32(x)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}
