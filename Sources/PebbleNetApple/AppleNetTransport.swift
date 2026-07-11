// The ONLY file allowed to depend on Apple's Network framework. Everything
// here just implements the portable NetTransport* protocols from PebbleCore
// (Sources/PebbleCore/Net/NetTransport.swift) on top of NWConnection/
// NWListener/NWBrowser — PebbleCore itself never sees a single Apple type.
//
// Nothing in this file runs unless something calls
// AppleNetTransportFactory.installAsDefault() (typically once, at app
// startup) — PebbleCore's default remains the portable in-memory transport
// until that happens, which is deliberate: PebbleCore must never assume this
// module exists.

import Foundation
import Network
import PebbleCore

public struct AppleNetTransportFactory: NetTransportFactory {
    public init() {}

    public func connect(to endpoint: NetEndpoint) throws -> any NetTransportConnection {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw NetTransportError.connectionRefused(endpoint)
        }
        let nw = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
        return AppleNetTransportConnection(nw)
    }

    public func listen(port: UInt16) throws -> any NetTransportListener {
        AppleNetTransportListener(requestedPort: port)
    }

    /// call once at process startup (e.g. Pebble/pebserver's main.swift) to
    /// make real sockets + Bonjour the process-wide default in place of the
    /// portable in-memory transport. Never called automatically.
    public static func installAsDefault() {
        NetTransportDefaults.factory = AppleNetTransportFactory()
        NetTransportDefaults.discoveryFactory = { AppleBonjourBrowser() }
    }
}

// =============================================================================
// connection
// =============================================================================
final class AppleNetTransportConnection: NetTransportConnection {
    private let nw: NWConnection
    private var frameCodec = FrameCodec()
    private var pendingMessages: [NetMsg] = []
    private var pendingClose: String?
    private var closed = false

    // nw.receive completions run on nw's own background queue (started
    // below) while onMessage/onClosed are assigned from whatever queue the
    // caller uses (main, in production, via a real async hop) — this lock
    // guards every field both sides touch so the two never race on it.
    private let stateLock = NSLock()
    private var rawOnMessage: ((NetMsg) -> Void)?
    private var rawOnClosed: ((String) -> Void)?

    // buffering: NWConnection.start() begins receiving immediately, before
    // the caller has necessarily assigned onMessage/onClosed — queue and
    // flush on assignment so nothing delivered in that window is lost
    var onMessage: ((NetMsg) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return rawOnMessage }
        set {
            stateLock.lock()
            rawOnMessage = newValue
            stateLock.unlock()
            flushMessages()
        }
    }
    var onClosed: ((String) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return rawOnClosed }
        set {
            stateLock.lock()
            rawOnClosed = newValue
            stateLock.unlock()
            flushClose()
        }
    }

    init(_ nw: NWConnection) {
        self.nw = nw
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let err): self?.finish("connection failed: \(err.localizedDescription)")
            case .cancelled: self?.finish("connection closed")
            default: break
            }
        }
        nw.start(queue: .global(qos: .userInitiated))
        receiveLoop()
    }

    private func receiveLoop() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.frameCodec.feed(data)
                self.drainFrames()
                if self.isClosedNow() { return }
            }
            if isComplete || error != nil {
                self.finish(error.map { "connection lost: \($0.localizedDescription)" } ?? "connection closed")
                return
            }
            self.receiveLoop()
        }
    }

    private func drainFrames() {
        while true {
            let frame: Data?
            do {
                frame = try frameCodec.next()
            } catch {
                finish("oversized frame")
                return
            }
            guard let frame else { return }
            if let msg = try? NetMsg.decode(frame) {
                deliver(msg)
                if isClosedNow() { return }   // handler may close mid-drain
            }
            // unknown/corrupt individual frames are skipped — forward compatibility
        }
    }

    private func deliver(_ msg: NetMsg) {
        FileHandle.standardError.write(Data("DEBUG deliver\n".utf8))
        stateLock.lock()
        pendingMessages.append(msg)
        stateLock.unlock()
        flushMessages()
    }
    // drains one message at a time under the lock, invoking the callback
    // outside it — safe against concurrent deliver()/onMessage-assignment
    // callers, and never holds the lock while user code runs
    private func flushMessages() {
        while true {
            stateLock.lock()
            guard let cb = rawOnMessage, !pendingMessages.isEmpty else {
                stateLock.unlock()
                return
            }
            let msg = pendingMessages.removeFirst()
            stateLock.unlock()
            cb(msg)
        }
    }

    private func isClosedNow() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return closed
    }

    private func finish(_ reason: String) {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        pendingClose = reason
        stateLock.unlock()
        nw.cancel()
        flushClose()
    }
    private func flushClose() {
        stateLock.lock()
        guard closed, let cb = rawOnClosed, let reason = pendingClose else {
            stateLock.unlock()
            return
        }
        pendingClose = nil
        stateLock.unlock()
        cb(reason)
    }

    func send(_ m: NetMsg) {
        guard !isClosedNow() else { FileHandle.standardError.write(Data("DEBUG send-skip-closed\n".utf8)); return }
        nw.send(content: FrameCodec.encode(m.encode()), completion: .contentProcessed { err in
            if let err { FileHandle.standardError.write(Data("DEBUG send-error \(err)\n".utf8)) }
        })
    }

    /// voluntary local close — matches the portable transports: the peer
    /// observes it through its own onClosed, this side's onClosed never
    /// fires for a close it initiated itself
    func close() {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        stateLock.unlock()
        nw.cancel()
    }
}

// =============================================================================
// listener (+ Bonjour advertising)
// =============================================================================
final class AppleNetTransportListener: NetTransportListener, NetServiceAdvertising {
    var onAccept: ((any NetTransportConnection) -> Void)?
    private(set) var boundPort: UInt16?

    private let requestedPort: UInt16
    private var listener: NWListener?
    private var pendingAdvertise: (serviceName: String, type: String, txt: [String: String])?

    init(requestedPort: UInt16) {
        self.requestedPort = requestedPort
    }

    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l: NWListener
        if requestedPort != 0, let p = NWEndpoint.Port(rawValue: requestedPort) {
            l = try NWListener(using: params, on: p)
        } else {
            l = try NWListener(using: params)
        }
        if let adv = pendingAdvertise {
            l.service = Self.bonjourService(adv)
        }
        l.newConnectionHandler = { [weak self] nw in
            self?.onAccept?(AppleNetTransportConnection(nw))
        }
        // NWListener startup is asynchronous; convert it into the synchronous
        // throwing start() the portable protocol expects
        let sem = DispatchSemaphore(value: 0)
        var startError: Error?
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.boundPort = l.port?.rawValue ?? 0
                sem.signal()
            case .failed(let err):
                startError = err
                sem.signal()
            default: break
            }
        }
        l.start(queue: .global(qos: .userInitiated))
        _ = sem.wait(timeout: .now() + 5)
        if let startError { l.cancel(); throw startError }
        guard boundPort != nil else { l.cancel(); throw NetTransportError.notListening }
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
        boundPort = nil
    }

    func advertise(serviceName: String, type: String, txt: [String: String]) {
        pendingAdvertise = (serviceName, type, txt)
        listener?.service = Self.bonjourService(pendingAdvertise!)
    }

    private static func bonjourService(_ adv: (serviceName: String, type: String, txt: [String: String])) -> NWListener.Service {
        var record = NWTXTRecord()
        for (k, v) in adv.txt { record[k] = v }
        return NWListener.Service(name: adv.serviceName, type: adv.type, txtRecord: record.data)
    }
}

// =============================================================================
// Bonjour discovery
// =============================================================================
public final class AppleDiscoveredService: NetDiscoveredService {
    public let name: String
    public let endpoint: NetEndpoint
    public let txt: [String: String]
    init(name: String, host: String, port: UInt16, txt: [String: String]) {
        self.name = name
        endpoint = NetEndpoint(host: host, port: port)
        self.txt = txt
    }
}

/// browses `_pebble._tcp` and resolves each result to a host:port before
/// surfacing it — NetDiscoveredService.endpoint must be genuinely dialable,
/// so unresolved/unresolvable services are simply never published rather
/// than exposed with a fake port.
public final class AppleBonjourBrowser: NetBrowsing {
    public var onUpdate: (([any NetDiscoveredService]) -> Void)?
    private var browser: NWBrowser?
    private var resolved: [String: AppleDiscoveredService] = [:]
    private var resolvers: [String: NWConnection] = [:]

    public init() {}

    public func start() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: NET_SERVICE_TYPE, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleResults(results)
        }
        b.start(queue: .main)
        browser = b
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        for (_, c) in resolvers { c.cancel() }
        resolvers.removeAll()
        resolved.removeAll()
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var seenNames = Set<String>()
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint else { continue }
            seenNames.insert(name)
            guard resolved[name] == nil, resolvers[name] == nil else { continue }
            var txt: [String: String] = [:]
            if case let .bonjour(rec) = r.metadata {
                for (key, entry) in rec {
                    if case let .string(s) = entry { txt[key] = s }
                }
            }
            resolve(name: name, endpoint: r.endpoint, txt: txt)
        }
        for name in resolved.keys where !seenNames.contains(name) {
            resolved.removeValue(forKey: name)
        }
        for name in resolvers.keys where !seenNames.contains(name) {
            resolvers[name]?.cancel()
            resolvers.removeValue(forKey: name)
        }
        publish()
    }

    /// Bonjour service endpoints aren't a host:port until dialed — resolve
    /// via a throwaway connection and read back the resolved remote endpoint
    private func resolve(name: String, endpoint: NWEndpoint, txt: [String: String]) {
        let c = NWConnection(to: endpoint, using: .tcp)
        resolvers[name] = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c else { return }
            switch state {
            case .ready:
                let hp = Self.hostPort(from: c.currentPath?.remoteEndpoint)
                c.cancel()
                self.resolvers.removeValue(forKey: name)
                if let (host, port) = hp {
                    self.resolved[name] = AppleDiscoveredService(name: name, host: host, port: port, txt: txt)
                    self.publish()
                }
            case .failed, .cancelled:
                c.cancel()
                self.resolvers.removeValue(forKey: name)
            default: break
            }
        }
        c.start(queue: .main)
    }

    private static func hostPort(from endpoint: NWEndpoint?) -> (String, UInt16)? {
        guard case let .hostPort(host, port) = endpoint else { return nil }
        let hostStr: String
        switch host {
        case .ipv4(let a): hostStr = "\(a)"
        case .ipv6(let a): hostStr = "\(a)"
        case .name(let n, _): hostStr = n
        @unknown default: return nil
        }
        return (hostStr, port.rawValue)
    }

    private func publish() {
        onUpdate?(resolved.values.sorted { $0.name < $1.name })
    }
}
