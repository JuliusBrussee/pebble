// LAN transport — Network.framework TCP with Bonjour discovery. Frames are
// [u32 little-endian length][message bytes]. All callbacks hop to the main
// queue: the whole game sim is main-thread, so the net layer must be too.

import Foundation
import Network

/// one framed TCP connection (host-side accepted socket, or the guest's link)
public final class NetConnection {
    let conn: NWConnection
    /// application tag (the host hangs its per-guest state here)
    public var tag: AnyObject?
    public var onMessage: ((NetMsg) -> Void)?
    public var onClosed: ((String) -> Void)?
    public private(set) var closed = false
    private var buffer = Data()

    public init(_ conn: NWConnection) {
        self.conn = conn
    }

    public func start() {
        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .failed(let err): self?.finish("connection failed: \(err.localizedDescription)")
                case .cancelled: self?.finish("connection closed")
                default: break
                }
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        receiveLoop()
    }

    private func receiveLoop() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // hand the bytes to the main thread, but RE-ARM the receive right
            // here on the connection's queue — re-arming after the main-thread
            // hop capped throughput at one read per frame and backed up floods
            if let data, !data.isEmpty {
                DispatchQueue.main.async {
                    self.buffer.append(data)
                    self.drainFrames()
                }
            }
            if isComplete || error != nil {
                DispatchQueue.main.async {
                    self.finish(error.map { "connection lost: \($0.localizedDescription)" } ?? "connection closed")
                }
                return
            }
            if !self.closed { self.receiveLoop() }
        }
    }

    private func drainFrames() {
        while buffer.count >= 4 {
            let len = Int(UInt32(littleEndian: buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            if len > NET_MAX_FRAME {
                finish("oversized frame (\(len) bytes)")
                return
            }
            guard buffer.count >= 4 + len else { return }
            let frame = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + 4 + len))
            buffer.removeFirst(4 + len)
            if let msg = try? NetMsg.decode(frame) {
                onMessage?(msg)
                if closed { return }   // handler may close mid-drain
            }
            // unknown/corrupt frames are skipped — forward compatibility
        }
    }

    public func send(_ msg: NetMsg) {
        if closed { return }
        let body = msg.encode()
        var frame = Data(capacity: body.count + 4)
        var le = UInt32(body.count).littleEndian
        withUnsafeBytes(of: &le) { frame.append(contentsOf: $0) }
        frame.append(body)
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    public func close() {
        if closed { return }
        closed = true
        conn.cancel()
    }

    private func finish(_ reason: String) {
        if closed { return }
        closed = true
        conn.cancel()
        onClosed?(reason)
    }
}

/// host side: listens on TCP and advertises via Bonjour as "name" on _pebble._tcp.
/// TXT record carries presence metadata (host pid/name/world) for friends lists.
public final class NetListener {
    private var listener: NWListener?
    public var onConnection: ((NetConnection) -> Void)?
    public private(set) var port: UInt16 = 0

    public init() {}

    public func start(serviceName: String, fixedPort: UInt16? = nil, txt: [String: String] = [:]) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l: NWListener
        if let fixedPort, let p = NWEndpoint.Port(rawValue: fixedPort) {
            l = try NWListener(using: params, on: p)
        } else {
            l = try NWListener(using: params)
        }
        var record = NWTXTRecord()
        for (k, v) in txt { record[k] = v }
        l.service = NWListener.Service(name: serviceName, type: NET_SERVICE_TYPE,
                                       txtRecord: record.data)
        l.newConnectionHandler = { [weak self] nw in
            let c = NetConnection(nw)
            DispatchQueue.main.async {
                self?.onConnection?(c)
                c.start()
            }
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                DispatchQueue.main.async { self?.port = l.port?.rawValue ?? 0 }
            }
        }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// guest side: browse for LAN games (TXT metadata included for presence)
public final class NetBrowser {
    public struct Found {
        public let name: String
        public let endpoint: NWEndpoint
        /// advertised metadata: "pid", "name", "world", "ver" (may be empty)
        public let txt: [String: String]
    }
    private var browser: NWBrowser?
    public var onUpdate: (([Found]) -> Void)?

    public init() {}

    public func start() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: NET_SERVICE_TYPE, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> Found? in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                var txt: [String: String] = [:]
                if case let .bonjour(rec) = r.metadata {
                    for (key, entry) in rec {
                        if case let .string(s) = entry { txt[key] = s }
                    }
                }
                return Found(name: name, endpoint: r.endpoint, txt: txt)
            }.sorted { $0.name < $1.name }
            DispatchQueue.main.async { self?.onUpdate?(found) }
        }
        b.start(queue: .global(qos: .userInitiated))
        browser = b
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// dial a discovered game (or a literal host:port for testing)
public func netDial(_ endpoint: NWEndpoint) -> NetConnection {
    NetConnection(NWConnection(to: endpoint, using: .tcp))
}
public func netDial(host: String, port: UInt16) -> NetConnection {
    NetConnection(NWConnection(host: NWEndpoint.Host(host),
                               port: NWEndpoint.Port(rawValue: port) ?? 25585, using: .tcp))
}
