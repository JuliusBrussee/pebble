// Adler-32 checksum (RFC 1950 zlib trailer). Pure Swift, no zlib/Compression.

public enum Adler32 {
    private static let modAdler: UInt32 = 65521

    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % modAdler
            b = (b + a) % modAdler
        }
        return (b << 16) | a
    }
}
