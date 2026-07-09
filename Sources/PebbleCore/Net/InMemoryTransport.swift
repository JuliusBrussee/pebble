// Loopback transport — no sockets, no Network.framework, works identically on
// macOS, Linux and Windows. This is what makes NetHostSession/NetGuestSession
// testable everywhere (pebsmoke's "open to LAN, then join" flow runs entirely
// over this), and it's also the process-wide default until an app entry point
// installs a real backend (see NetTransportDefaults in NetTransport.swift).
//
// "Ports" here are just keys into an in-process registry — nothing touches
// the OS network stack. Two peers only ever connect if they're in the same
// process, which is exactly what the smoke/test harnesses need.

import Foundation

public final class InMemoryTransportFactory: NetTransportFactory, @unchecked Sendable {
    public static let shared = InMemoryTransportFactory()

    private let lock = NSLock()
    private var listeners: [UInt16: InMemoryListener] = [:]
    private var nextEphemeralPort: UInt16 = 40000

    public init() {}

    public func listen(port: UInt16) throws -> any NetTransportListener {
        InMemoryListener(requestedPort: port, factory: self)
    }

    public func connect(to endpoint: NetEndpoint) throws -> any NetTransportConnection {
        lock.lock()
        let listener = listeners[endpoint.port]
        lock.unlock()
        guard let listener else { throw NetTransportError.connectionRefused(endpoint) }
        let (clientSide, serverSide) = InMemoryConnection.makePair()
        listener.accept(serverSide)
        return clientSide
    }

    /// called only from InMemoryListener.start() — binds (or auto-assigns) a port
    fileprivate func register(_ listener: InMemoryListener, requestedPort: UInt16) throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        var p = requestedPort
        if p == 0 {
            var candidate = nextEphemeralPort
            while listeners[candidate] != nil {
                candidate = candidate == .max ? 40000 : candidate + 1
            }
            p = candidate
            nextEphemeralPort = candidate == .max ? 40000 : candidate + 1
        } else {
            guard listeners[p] == nil else { throw NetTransportError.portInUse(p) }
        }
        listeners[p] = listener
        return p
    }

    fileprivate func unregister(_ port: UInt16) {
        lock.lock(); defer { lock.unlock() }
        listeners.removeValue(forKey: port)
    }
}

public final class InMemoryListener: NetTransportListener {
    public var onAccept: ((any NetTransportConnection) -> Void)?
    public private(set) var boundPort: UInt16?

    private let requestedPort: UInt16
    private let factory: InMemoryTransportFactory

    fileprivate init(requestedPort: UInt16, factory: InMemoryTransportFactory) {
        self.requestedPort = requestedPort
        self.factory = factory
    }

    public func start() throws {
        guard boundPort == nil else { return }
        boundPort = try factory.register(self, requestedPort: requestedPort)
    }

    public func stop() {
        guard let p = boundPort else { return }
        boundPort = nil
        factory.unregister(p)
    }

    fileprivate func accept(_ conn: InMemoryConnection) {
        onAccept?(conn)
    }
}

public final class InMemoryConnection: NetTransportConnection {
    fileprivate weak var peer: InMemoryConnection?
    /// real framed bytes flow between the two ends — every message actually
    /// goes through NetMsg.encode()/FrameCodec/NetMsg.decode(), same as a
    /// real socket, so encode/decode bugs show up in session tests too
    private var frameCodec = FrameCodec()
    private var pendingMessages: [NetMsg] = []
    private var pendingClose: String?
    private var closed = false

    // buffering: a peer may send/close before this side's owner has had a
    // chance to assign onMessage/onClosed (accept happens synchronously
    // inside connect()) — queue and flush on assignment so nothing is lost
    public var onMessage: ((NetMsg) -> Void)? {
        didSet { flushMessages() }
    }
    public var onClosed: ((String) -> Void)? {
        didSet { flushClose() }
    }

    fileprivate init() {}

    /// a connected pair. Callers are expected to retain both ends (one via
    /// whatever they wrap the "client" side in, the other via the listener's
    /// onAccept handler) — this type does not retain its peer.
    public static func makePair() -> (InMemoryConnection, InMemoryConnection) {
        let a = InMemoryConnection()
        let b = InMemoryConnection()
        a.peer = b
        b.peer = a
        return (a, b)
    }

    fileprivate func receive(_ framed: Data) {
        guard !closed else { return }
        frameCodec.feed(framed)
        while true {
            let frame: Data?
            do {
                frame = try frameCodec.next()
            } catch {
                // oversize frame: hard disconnect, same policy as the Apple
                // adapter — never wait it out, never keep buffering
                let reason = "oversized frame"
                peer?.deliverClosed(reason)
                deliverClosed(reason)
                return
            }
            guard let frame else { break }
            if let msg = try? NetMsg.decode(frame) {
                pendingMessages.append(msg)
            }
            // unknown/corrupt individual frames are skipped — forward
            // compatibility, same policy as every other adapter
        }
        flushMessages()
    }
    private func flushMessages() {
        guard let cb = onMessage else { return }
        while !pendingMessages.isEmpty { cb(pendingMessages.removeFirst()) }
    }

    fileprivate func deliverClosed(_ reason: String) {
        guard !closed else { return }
        closed = true
        pendingClose = reason
        flushClose()
    }
    private func flushClose() {
        guard closed, let cb = onClosed, let reason = pendingClose else { return }
        pendingClose = nil
        cb(reason)
    }

    public func send(_ m: NetMsg) {
        guard !closed else { return }
        peer?.receive(FrameCodec.encode(m.encode()))
    }

    /// voluntary local close — matches the old NetConnection.close(): the
    /// peer is notified via its onClosed, this side's own onClosed never
    /// fires for a close it initiated itself
    public func close() {
        guard !closed else { return }
        closed = true
        peer?.deliverClosed("connection closed")
    }
}
