// Portable transport abstraction. No Apple Network.framework here — the
// concrete Apple socket/Bonjour implementation lives in PebbleNetApple, the
// only place allowed to depend on that framework. Frames are
// [u32 LE length][bytes]; FrameCodec below is the single place that
// framing/truncation/oversize logic lives, shared by every adapter.

import Foundation

/// one framed connection to a peer, regardless of what's underneath it
/// (Apple sockets, a native CPebblePlatform socket, or an in-memory pair).
public protocol NetTransportConnection: AnyObject {
    var onMessage: ((NetMsg) -> Void)? { get set }
    var onClosed: ((String) -> Void)? { get set }
    func send(_ m: NetMsg)
    func close()
}

/// accepts inbound connections on a bound port.
public protocol NetTransportListener: AnyObject {
    var onAccept: ((any NetTransportConnection) -> Void)? { get set }
    var boundPort: UInt16? { get }
    func start() throws
    func stop()
}

/// builds connections/listeners. Factories are handed around across threads
/// (a session may be constructed off the main thread in tests), hence Sendable.
public protocol NetTransportFactory: Sendable {
    func connect(to: NetEndpoint) throws -> any NetTransportConnection
    func listen(port: UInt16) throws -> any NetTransportListener
}

/// optional capability: a listener that can also announce itself via service
/// discovery (Bonjour on Apple). Transports without discovery (in-memory, a
/// future direct-TCP adapter) simply don't conform — callers downcast.
public protocol NetServiceAdvertising: AnyObject {
    func advertise(serviceName: String, type: String, txt: [String: String])
}

/// one discovered peer (LAN Bonjour browsing, or any future discovery source).
public protocol NetDiscoveredService {
    var name: String { get }
    var endpoint: NetEndpoint { get }
    /// advertised metadata: "pid", "name", "world", "ver" (may be empty)
    var txt: [String: String] { get }
}

/// browses for LAN games. The only concrete, working implementation today is
/// AppleBonjourBrowser in PebbleNetApple; portable code only ever sees this.
public protocol NetBrowsing: AnyObject {
    var onUpdate: (([any NetDiscoveredService]) -> Void)? { get set }
    func start()
    func stop()
}

public enum NetTransportError: Error, Equatable {
    case portInUse(UInt16)
    case connectionRefused(NetEndpoint)
    case notListening
}

// =============================================================================
// FrameCodec — the single owner of [u32 LE length][bytes] framing
// =============================================================================
/// stream → frames, and back. Every adapter (Apple, in-memory, future direct
/// TCP) feeds raw bytes in and pulls decoded-message-sized frames out through
/// this one codec, so the truncation/oversize/reassembly logic exists exactly
/// once.
public struct FrameCodec {
    /// a declared frame length exceeded NET_MAX_FRAME. This is a hard
    /// disconnect, not something to wait out — a corrupt or hostile length
    /// prefix must never make the receiver buffer unbounded memory.
    public struct OversizeFrame: Error, Equatable { public let length: Int }

    private var buf = Data()
    public init() {}

    public mutating func feed(_ data: Data) {
        buf.append(data)
    }

    /// pops the next complete frame's payload, or nil if more bytes are
    /// needed. A zero-length frame (declared length 0) is valid and returns
    /// an empty Data — NetMsg.decode of that will itself throw .underflow,
    /// which is the correct rejection for "a frame with no type byte".
    public mutating func next() throws -> Data? {
        guard buf.count >= 4 else { return nil }   // truncated header — wait for more
        let len = Int(UInt32(littleEndian: buf.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        if len > NET_MAX_FRAME { throw OversizeFrame(length: len) }
        guard buf.count >= 4 + len else { return nil }   // truncated payload — wait for more
        let frame = buf.subdata(in: (buf.startIndex + 4)..<(buf.startIndex + 4 + len))
        buf.removeFirst(4 + len)
        return frame
    }

    public static func encode(_ body: Data) -> Data {
        var frame = Data(capacity: body.count + 4)
        var le = UInt32(body.count).littleEndian
        withUnsafeBytes(of: &le) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame
    }
}

// =============================================================================
// process-wide default factory/discovery — late-bound so PebbleCore never has
// to know Apple exists. PebbleNetApple installs the real backend at app
// startup (AppleNetTransportFactory.installAsDefault()); until that happens,
// the default is the portable in-memory transport, which is correct for
// same-process tests (pebsmoke) but cannot reach another machine.
// =============================================================================
public enum NetTransportDefaults: @unchecked Sendable {
    public static var factory: any NetTransportFactory = InMemoryTransportFactory.shared
    /// nil until something (AppleBonjourBrowser) installs a real backend —
    /// LanScreens then simply sees zero discovered games, never a crash
    public static var discoveryFactory: (@Sendable () -> any NetBrowsing)?
}

// =============================================================================
// source-compat shims — GameCore.swift, pebserver, pebsmoke, and LanScreens
// keep constructing/passing these exact names; only what's behind them moved
// =============================================================================
/// what used to be the concrete Apple-backed connection class is now just the
/// protocol existential — every call site that wrote `NetConnection` keeps compiling
public typealias NetConnection = any NetTransportConnection

/// dial an endpoint using the process-wide default factory. Non-throwing
/// (the old API was non-throwing): a failed dial still returns a connection,
/// which reports the failure through `onClosed` once a handler is attached.
public func netDial(_ endpoint: NetEndpoint) -> NetConnection {
    do {
        return try NetTransportDefaults.factory.connect(to: endpoint)
    } catch {
        return FailedConnection(reason: "\(error)")
    }
}
public func netDial(host: String, port: UInt16) -> NetConnection {
    netDial(NetEndpoint(host: host, port: port))
}

/// a connection that was never actually established — reports its failure
/// to whichever handler gets attached (there is no reliable "already failed"
/// signal in the NetTransportConnection surface otherwise)
final class FailedConnection: NetTransportConnection {
    private let reason: String
    private var delivered = false
    var onMessage: ((NetMsg) -> Void)?
    var onClosed: ((String) -> Void)? {
        didSet { deliver() }
    }
    init(reason: String) { self.reason = reason }
    private func deliver() {
        guard !delivered, let cb = onClosed else { return }
        delivered = true
        cb(reason)
    }
    func send(_ m: NetMsg) {}
    func close() {}
}
