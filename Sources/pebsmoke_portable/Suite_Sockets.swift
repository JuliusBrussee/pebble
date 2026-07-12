import Foundation
import Dispatch
import PebblePlatformNative

private final class SocketSuiteResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Data, Error>?

    func set(_ result: Result<Data, Error>) {
        lock.lock(); value = result; lock.unlock()
    }

    func get() -> Result<Data, Error>? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

public struct SocketsSuite: PortableSuite {
    public static let name = "sockets"

    public static func run(_ h: inout SmokeHarness) {
        h.check("platform ABI layout matches", PebblePlatform.layoutMatchesHeader())
        h.eq("platform ABI version", PebblePlatform.abiVersion, 2)
        do {
            let capabilities = try PebblePlatform.capabilities()
            h.eq("capabilities ABI version", capabilities.abiVersion, PebblePlatform.abiVersion)
            h.check("native sockets capability", capabilities.hasSockets)
        } catch {
            h.check("capabilities ABI version", false)
            h.check("native sockets capability", false)
        }

        h.check("empty host rejected", connectionFails(host: "", port: 1))
        h.check("zero port rejected", connectionFails(host: "127.0.0.1", port: 0))

        do {
            let listening = try NativeSocket.listen(port: 0, backlog: 1)
            h.check("ephemeral listener gets port", listening.port != 0)

            let result = SocketSuiteResult()
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                defer { finished.signal() }
                do {
                    let accepted = try listening.socket.accept()
                    let request = try accepted.receive(maxBytes: 4) ?? Data()
                    try accepted.send(Data("pong".utf8))
                    try accepted.shutdownWrite()
                    result.set(.success(request))
                } catch {
                    result.set(.failure(error))
                }
            }

            let client = try NativeSocket.connect(host: "127.0.0.1", port: listening.port)
            try client.send(Data("ping".utf8))
            try client.shutdownWrite()
            h.eq("loopback response", try client.receive(maxBytes: 4), Data("pong".utf8))
            h.check("loopback EOF after shutdown", try client.receive(maxBytes: 4) == nil)
            h.eq("loopback server completed", finished.wait(timeout: .now() + 5), .success)
            switch result.get() {
            case .success(let request): h.eq("loopback request", request, Data("ping".utf8))
            default: h.check("loopback request", false)
            }

            listening.socket.interrupt()
            listening.socket.interrupt()
            h.check("socket interrupt is idempotent", true)
        } catch {
            h.check("ephemeral listener gets port", false)
            h.check("loopback response", false)
            h.check("loopback EOF after shutdown", false)
            h.check("loopback server completed", false)
            h.check("loopback request", false)
            h.check("socket interrupt is idempotent", false)
        }
    }

    private static func connectionFails(host: String, port: UInt16) -> Bool {
        do {
            _ = try NativeSocket.connect(host: host, port: port)
            return false
        } catch {
            return true
        }
    }
}
