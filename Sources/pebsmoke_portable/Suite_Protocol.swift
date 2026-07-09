// ProtocolSuite ("protocol") — pins the LAN wire format and exercises the
// portable transport primitives without any Apple/OS networking. Everything
// here runs identically on macOS, Linux and Windows, since it only touches
// PebbleCore (which the C1-C5 lane rewrite guarantees is import-Network-free).
//
// Integration: conforms to PortableSuite like every other pebsmoke_portable
// suite; internally still built around the (name, cond, detail) -> Void
// check shape the lane wrote, adapted onto SmokeHarness by run(_:).

import Foundation
import PebbleCore

public struct ProtocolSuite: PortableSuite {
    public static let name = "protocol"

    public static func run(_ h: inout SmokeHarness) {
        var local = SmokeHarness()
        let check: (_ name: String, _ cond: Bool, _ detail: String) -> Void = { name, cond, detail in
            local.check(cond || detail.isEmpty ? name : "\(name): \(detail)", cond)
        }
        goldenBytes(check)
        frameCodec(check)
        decodeErrors(check)
        endpointParsing(check)
        inMemoryRoundTrip(check)
        stableWireOrder(check)
        h = local
    }

    // =========================================================================
    // golden byte fixtures — hardcoded expected bytes for 5 message types.
    // If NetMsg's binary layout ever changes, these fail loudly: the wire
    // format is pinned by NET_PROTOCOL_VERSION, which this lane must not bump.
    // =========================================================================
    private static func goldenBytes(_ check: (String, Bool, String) -> Void) {
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

        // .goodbye — typeId 13, empty payload
        do {
            let golden: [UInt8] = [13]
            let msg = NetMsg.goodbye
            check("golden bytes: goodbye", [UInt8](msg.encode()) == golden, "got \(hex(msg.encode()))")
            switch try? NetMsg.decode(Data(golden)) {
            case .goodbye: check("golden decode: goodbye", true, "")
            default: check("golden decode: goodbye", false, "wrong case or threw")
            }
        }

        // .chunkReq(dim: 1, cx: 2, cz: -3) — typeId 2
        do {
            let golden: [UInt8] = [2, 1, 2, 0, 0, 0, 253, 255, 255, 255]
            let msg = NetMsg.chunkReq(dim: 1, cx: 2, cz: -3)
            check("golden bytes: chunkReq", [UInt8](msg.encode()) == golden, "got \(hex(msg.encode()))")
            if case let .chunkReq(dim, cx, cz)? = try? NetMsg.decode(Data(golden)) {
                check("golden decode: chunkReq", dim == 1 && cx == 2 && cz == -3, "got dim=\(dim) cx=\(cx) cz=\(cz)")
            } else {
                check("golden decode: chunkReq", false, "wrong case or threw")
            }
        }

        // .chat("hi") — typeId 11
        do {
            let golden: [UInt8] = [11, 2, 0, 104, 105]
            let msg = NetMsg.chat(text: "hi")
            check("golden bytes: chat", [UInt8](msg.encode()) == golden, "got \(hex(msg.encode()))")
            if case let .chat(text)? = try? NetMsg.decode(Data(golden)) {
                check("golden decode: chat", text == "hi", "got \(text)")
            } else {
                check("golden decode: chat", false, "wrong case or threw")
            }
        }

        // .disconnect("bye") — typeId 48
        do {
            let golden: [UInt8] = [48, 3, 0, 98, 121, 101]
            let msg = NetMsg.disconnect(reason: "bye")
            check("golden bytes: disconnect", [UInt8](msg.encode()) == golden, "got \(hex(msg.encode()))")
            if case let .disconnect(reason)? = try? NetMsg.decode(Data(golden)) {
                check("golden decode: disconnect", reason == "bye", "got \(reason)")
            } else {
                check("golden decode: disconnect", false, "wrong case or threw")
            }
        }

        // .giveXP(5) — typeId 41
        do {
            let golden: [UInt8] = [41, 5, 0, 0, 0]
            let msg = NetMsg.giveXP(amount: 5)
            check("golden bytes: giveXP", [UInt8](msg.encode()) == golden, "got \(hex(msg.encode()))")
            if case let .giveXP(amount)? = try? NetMsg.decode(Data(golden)) {
                check("golden decode: giveXP", amount == 5, "got \(amount)")
            } else {
                check("golden decode: giveXP", false, "wrong case or threw")
            }
        }
    }

    // =========================================================================
    // FrameCodec — [u32 LE length][bytes] reassembly, truncation, oversize
    // =========================================================================
    private static func frameCodec(_ check: (String, Bool, String) -> Void) {
        // single frame, one read
        do {
            var fc = FrameCodec()
            let body = Data([1, 2, 3])
            fc.feed(FrameCodec.encode(body))
            let out = try? fc.next()
            check("framecodec: single frame round-trip", out == body, "got \(String(describing: out))")
        }

        // header split across two feeds
        do {
            var fc = FrameCodec()
            let body = Data([9, 9, 9, 9, 9])
            let framed = FrameCodec.encode(body)
            fc.feed(framed.prefix(2))
            let mid = try? fc.next()
            check("framecodec: split header returns nil until complete", mid == nil, "got \(String(describing: mid))")
            fc.feed(framed.dropFirst(2))
            let out = try? fc.next()
            check("framecodec: reassembles after split header", out == body, "got \(String(describing: out))")
        }

        // payload split across two feeds
        do {
            var fc = FrameCodec()
            let body = Data(repeating: 7, count: 10)
            let framed = FrameCodec.encode(body)
            fc.feed(framed.prefix(6))   // full 4-byte header + 2 payload bytes
            let mid = try? fc.next()
            check("framecodec: truncated payload returns nil until complete", mid == nil, "got \(String(describing: mid))")
            fc.feed(framed.dropFirst(6))
            let out = try? fc.next()
            check("framecodec: reassembles after split payload", out == body, "got \(String(describing: out))")
        }

        // two frames delivered in a single read
        do {
            var fc = FrameCodec()
            let a = Data([1, 1])
            let b = Data([2, 2, 2])
            fc.feed(FrameCodec.encode(a) + FrameCodec.encode(b))
            let outA = try? fc.next()
            let outB = try? fc.next()
            let outC = try? fc.next()
            check("framecodec: two frames in one read — first", outA == a, "got \(String(describing: outA))")
            check("framecodec: two frames in one read — second", outB == b, "got \(String(describing: outB))")
            check("framecodec: no phantom third frame", outC == nil, "got \(String(describing: outC))")
        }

        // zero-length frame is a valid frame (empty payload), rejected only
        // at the message-decode layer, never at the framing layer
        do {
            var fc = FrameCodec()
            fc.feed(FrameCodec.encode(Data()))
            let out = try? fc.next()
            check("framecodec: zero-length frame is a valid empty payload", out == Data(), "got \(String(describing: out))")
            var messageThrew = false
            do { _ = try NetMsg.decode(Data()) } catch { messageThrew = true }
            check("framecodec: zero-length frame's payload is a rejected message", messageThrew, "")
        }

        // truncated header (fewer than 4 length-prefix bytes)
        do {
            var fc = FrameCodec()
            fc.feed(Data([1, 2]))
            let out = try? fc.next()
            check("framecodec: truncated header (< 4 bytes) returns nil", out == nil, "got \(String(describing: out))")
        }

        // oversize frame — hard disconnect (throws), never waited out
        do {
            var fc = FrameCodec()
            var header = Data()
            var le = UInt32(NET_MAX_FRAME + 1).littleEndian
            withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
            fc.feed(header)
            var threw = false
            do { _ = try fc.next() } catch is FrameCodec.OversizeFrame { threw = true } catch {}
            check("framecodec: oversize frame throws OversizeFrame", threw, "")
        }
    }

    // =========================================================================
    // NetMsg.decode error policy
    // =========================================================================
    private static func decodeErrors(_ check: (String, Bool, String) -> Void) {
        // unknown message type
        do {
            var gotBadType: UInt8?
            do { _ = try NetMsg.decode(Data([200])) }
            catch NetProtocolError.badType(let t) { gotBadType = t }
            catch {}
            check("decode: unknown type throws badType(200)", gotBadType == 200, "got \(String(describing: gotBadType))")
        }

        // trailing bytes after a fully-decoded message
        do {
            var frame = Data([13])   // goodbye, complete on its own
            frame.append(0xFF)       // one stray extra byte
            var gotN: Int?
            do { _ = try NetMsg.decode(frame) }
            catch NetProtocolError.trailingBytes(let n) { gotN = n }
            catch {}
            check("decode: trailing byte throws trailingBytes(1)", gotN == 1, "got \(String(describing: gotN))")
        }

        // short/truncated payload (chunkReq needs 10 bytes total, give 3)
        do {
            var threw = false
            do { _ = try NetMsg.decode(Data([2, 1, 2])) } catch NetProtocolError.underflow { threw = true } catch {}
            check("decode: short payload throws underflow", threw, "")
        }

        // non-zero Data.startIndex must decode identically to a zero-based buffer
        do {
            var buf = Data([0xAA, 0xAA, 0xAA])
            buf.append(NetMsg.giveXP(amount: 42).encode())
            let slice = buf.suffix(from: buf.startIndex + 3)
            let sliceHasOffset = slice.startIndex != buf.startIndex
            check("decode: constructed a non-zero-startIndex Data slice", sliceHasOffset, "startIndex=\(slice.startIndex)")
            if case let .giveXP(amount)? = try? NetMsg.decode(slice) {
                check("decode: non-zero startIndex Data decodes correctly", amount == 42, "got \(amount)")
            } else {
                check("decode: non-zero startIndex Data decodes correctly", false, "decode failed")
            }
        }
    }

    // =========================================================================
    // NetEndpoint.parse — accept table + reject table (>= 10 cases)
    // =========================================================================
    private static func endpointParsing(_ check: (String, Bool, String) -> Void) {
        func expectOK(_ raw: String, host: String, port: UInt16, _ label: String) {
            switch NetEndpoint.parse(raw) {
            case .success(let ep):
                check("endpoint parse: \(label)", ep.host == host && ep.port == port, "got \(ep.host):\(ep.port)")
            case .failure(let e):
                check("endpoint parse: \(label)", false, "unexpected failure \(e)")
            }
        }
        func expectFail(_ raw: String, _ label: String) {
            switch NetEndpoint.parse(raw) {
            case .success(let ep):
                check("endpoint parse: \(label) is rejected", false, "unexpectedly parsed as \(ep.host):\(ep.port)")
            case .failure:
                check("endpoint parse: \(label) is rejected", true, "")
            }
        }

        expectOK("1.2.3.4:1234", host: "1.2.3.4", port: 1234, "ipv4:port")
        expectOK("host.local:1234", host: "host.local", port: 1234, "hostname:port")
        expectOK("[::1]:1234", host: "::1", port: 1234, "bracketed ipv6 + port")
        expectOK("[::1]", host: "::1", port: NetEndpoint.defaultPort, "bracketed ipv6, default port")
        expectOK("host.local", host: "host.local", port: NetEndpoint.defaultPort, "bare hostname, default port")
        expectOK("127.0.0.1", host: "127.0.0.1", port: NetEndpoint.defaultPort, "bare ipv4, default port")

        expectFail("", "empty string")
        expectFail("host:0", "port 0")
        expectFail("host:99999", "port > 65535")
        expectFail("::1:1234", "unbracketed ipv6")
        expectFail("host:", "empty port")
        expectFail(":1234", "empty host")
    }

    // =========================================================================
    // InMemoryTransport — a real NetMsg round-tripped through the exact
    // encode/decode path a session uses (send() encodes + frames it; the
    // peer's FrameCodec + NetMsg.decode() reassemble it)
    // =========================================================================
    private static func inMemoryRoundTrip(_ check: (String, Bool, String) -> Void) {
        let factory = InMemoryTransportFactory()
        guard let listener = try? factory.listen(port: 0) else {
            check("inmemory: listen()", false, "threw")
            return
        }
        var accepted: (any NetTransportConnection)?
        listener.onAccept = { accepted = $0 }
        do {
            try listener.start()
        } catch {
            check("inmemory: listener.start()", false, "\(error)")
            return
        }
        guard let port = listener.boundPort else {
            check("inmemory: listener bound a nonzero port", false, "")
            return
        }
        check("inmemory: listener bound a nonzero port", port != 0, "got \(port)")

        guard let client = try? factory.connect(to: NetEndpoint(host: "local", port: port)) else {
            check("inmemory: connect()", false, "threw")
            return
        }
        check("inmemory: listener accepted the connection", accepted != nil, "")

        var received: NetMsg?
        accepted?.onMessage = { received = $0 }
        client.send(.chat(text: "hello from the client"))
        if case let .chat(text)? = received {
            check("inmemory: round-trip through NetMsg.encode/FrameCodec/decode", text == "hello from the client", "got \(text)")
        } else {
            check("inmemory: round-trip through NetMsg.encode/FrameCodec/decode", false, "no message received")
        }
        listener.stop()
    }

    // =========================================================================
    // stable wire order (C2) — Set/Dictionary iteration must never leak into
    // the wire unsorted
    // =========================================================================
    private static func stableWireOrder(_ check: (String, Bool, String) -> Void) {
        // the pattern NetSession uses for entityRemove: Set<Int> -> sorted -> wire
        let ids: Set<Int> = [50, 1, 7, 23, 4]
        let sortedTwice = ids.sorted() == ids.sorted()
        check("wire order: Set.sorted() is deterministic across calls", sortedTwice, "")
        check("wire order: Set.sorted() is actually ascending", ids.sorted() == [1, 4, 7, 23, 50], "got \(ids.sorted())")

        // the pattern NetSession uses for NetWelcome/NetTimeSync: a Dictionary
        // payload encoded with a sortedKeys JSONEncoder must have alphabetical
        // key order in the output regardless of the dictionary's internal order
        var wel = NetWelcome()
        wel.players = ["3": "charlie", "1": "alpha", "2": "bravo"]
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(wel), let json = String(data: data, encoding: .utf8) {
            guard let i1 = json.range(of: "\"1\""), let i2 = json.range(of: "\"2\""), let i3 = json.range(of: "\"3\"") else {
                check("wire order: sortedKeys JSON has ascending dictionary key order", false, "keys missing from output")
                return
            }
            check("wire order: sortedKeys JSON has ascending dictionary key order",
                  i1.lowerBound < i2.lowerBound && i2.lowerBound < i3.lowerBound, "")
        } else {
            check("wire order: sortedKeys JSON has ascending dictionary key order", false, "encode failed")
        }
    }
}
