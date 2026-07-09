// RFC 1950 zlib stream wrapper around Inflate: CMF/FLG header validation plus
// an optional trailing Adler-32 verify. No Compression/zlib linkage.

public enum ZlibError: Error, Equatable {
    case truncated
    case badHeader              // FCHECK failed, i.e. (CMF*256+FLG) % 31 != 0
    case unsupportedMethod      // CM != 8 (deflate), or FDICT set (preset dictionary)
    case adlerMismatch
}

public enum Zlib {
    /// inflate a zlib stream (2-byte header + deflate body + 4-byte big-endian Adler-32).
    /// verifyAdler defaults to true; the caller may skip it for a decode-only fast path.
    public static func inflate(_ input: [UInt8], maxOutputBytes: Int, verifyAdler: Bool = true) throws -> [UInt8] {
        guard input.count >= 2 else { throw ZlibError.truncated }
        let cmf = input[0], flg = input[1]
        guard (Int(cmf) * 256 + Int(flg)) % 31 == 0 else { throw ZlibError.badHeader }
        guard (cmf & 0x0F) == 8 else { throw ZlibError.unsupportedMethod }
        guard (flg & 0x20) == 0 else { throw ZlibError.unsupportedMethod } // FDICT (preset dictionary) unsupported

        let (output, consumed) = try Inflate.inflateCore(input, startByte: 2, maxOutputBytes: maxOutputBytes)
        guard verifyAdler else { return output }

        guard input.count >= consumed + 4 else { throw ZlibError.truncated }
        let want = (UInt32(input[consumed]) << 24) | (UInt32(input[consumed + 1]) << 16)
                 | (UInt32(input[consumed + 2]) << 8) | UInt32(input[consumed + 3])
        guard Adler32.checksum(output) == want else { throw ZlibError.adlerMismatch }
        return output
    }
}
