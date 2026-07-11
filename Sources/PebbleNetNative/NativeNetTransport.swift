import Foundation
import PebbleCore
import PebblePlatformNative

public struct NativeNetTransportFactory: NetTransportFactory {
    public init() {}

    public func connect(to endpoint: NetEndpoint) throws -> any NetTransportConnection {
        NativeNetTransportConnection(socket: try NativeSocket.connect(host: endpoint.host, port: endpoint.port))
    }

    public func listen(port: UInt16) throws -> any NetTransportListener {
        NativeNetTransportListener(requestedPort: port)
    }

    public static func installAsDefault() {
        NetTransportDefaults.factory = NativeNetTransportFactory()
    }
}

private final class NativeNetTransportConnection: NetTransportConnection, @unchecked Sendable {
    private let socket: NativeSocket
    private let stateLock = NSLock()
    private let sendLock = NSLock()
    private var codec = FrameCodec()
    private var queuedMessages: [NetMsg] = []
    private var queuedClose: String?
    private var closed = false
    private var messageHandler: ((NetMsg) -> Void)?
    private var closeHandler: ((String) -> Void)?

    var onMessage: ((NetMsg) -> Void)? {
        get { withState { messageHandler } }
        set {
            withState { messageHandler = newValue }
            flushMessages()
        }
    }

    var onClosed: ((String) -> Void)? {
        get { withState { closeHandler } }
        set {
            withState { closeHandler = newValue }
            flushClose()
        }
    }

    init(socket: NativeSocket) {
        self.socket = socket
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.receiveLoop() }
    }

    func send(_ message: NetMsg) {
        guard !withState({ closed }) else { return }
        sendLock.lock()
        defer { sendLock.unlock() }
        do {
            try socket.send(FrameCodec.encode(message.encode()))
        } catch {
            finish("send failed: \(error)")
        }
    }

    func close() {
        let shouldClose = withState {
            guard !closed else { return false }
            closed = true
            return true
        }
        if shouldClose { socket.interrupt() }
    }

    private func receiveLoop() {
        do {
            while !withState({ closed }) {
                guard let bytes = try socket.receive() else {
                    finish("connection closed")
                    return
                }
                var decoded: [NetMsg] = []
                do {
                    try withState {
                        codec.feed(bytes)
                        while let frame = try codec.next() {
                            if let message = try? NetMsg.decode(frame) { decoded.append(message) }
                        }
                    }
                } catch {
                    finish("oversized frame")
                    return
                }
                if !decoded.isEmpty {
                    withState { queuedMessages.append(contentsOf: decoded) }
                    flushMessages()
                }
            }
        } catch {
            finish("receive failed: \(error)")
        }
    }

    private func finish(_ reason: String) {
        let shouldInterrupt = withState {
            guard !closed else { return false }
            closed = true
            queuedClose = reason
            return true
        }
        if shouldInterrupt { socket.interrupt() }
        flushClose()
    }

    private func flushMessages() {
        while true {
            let delivery: (((NetMsg) -> Void), NetMsg)? = withState {
                guard let handler = messageHandler, !queuedMessages.isEmpty else { return nil }
                return (handler, queuedMessages.removeFirst())
            }
            guard let delivery else { return }
            delivery.0(delivery.1)
        }
    }

    private func flushClose() {
        let delivery: (((String) -> Void), String)? = withState {
            guard let handler = closeHandler, let reason = queuedClose else { return nil }
            queuedClose = nil
            return (handler, reason)
        }
        if let delivery { delivery.0(delivery.1) }
    }

    @discardableResult
    private func withState<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }
}

private final class NativeNetTransportListener: NetTransportListener, @unchecked Sendable {
    var onAccept: ((any NetTransportConnection) -> Void)?
    private(set) var boundPort: UInt16?
    private let requestedPort: UInt16
    private let lock = NSLock()
    private var socket: NativeSocket?
    private var stopped = false

    init(requestedPort: UInt16) {
        self.requestedPort = requestedPort
    }

    func start() throws {
        lock.lock()
        if socket != nil { lock.unlock(); return }
        lock.unlock()
        let opened = try NativeSocket.listen(port: requestedPort)
        lock.lock()
        socket = opened.socket
        boundPort = opened.port
        stopped = false
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let current = socket
        socket = nil
        boundPort = nil
        lock.unlock()
        current?.interrupt()
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let current = socket
            let isStopped = stopped
            lock.unlock()
            guard !isStopped, let current else { return }
            do {
                let accepted = try current.accept()
                onAccept?(NativeNetTransportConnection(socket: accepted))
            } catch {
                lock.lock()
                let shouldContinue = !stopped
                lock.unlock()
                if !shouldContinue { return }
            }
        }
    }

    deinit { stop() }
}
