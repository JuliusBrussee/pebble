// A portable host:port address — the one thing every net transport needs to
// name a peer, without pulling in Network.framework's NWEndpoint. Used for
// manual server addresses ("host.local:25585"), saved ServerEntry rows, and
// discovered-service results.

import Foundation

public struct NetEndpoint: Equatable, Hashable {
    /// hostname, IPv4 literal, or a bare (unbracketed) IPv6 literal
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public static let defaultPort: UInt16 = 25585

    /// true if `host` looks like an IPv6 literal (contains a colon) — such
    /// hosts must be bracketed when rendered back into a "host:port" string
    public var hostLooksIPv6: Bool { host.contains(":") }

    /// renders back to the canonical wire form, bracketing IPv6 literals
    public var description: String {
        hostLooksIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

public enum NetEndpointError: Error, Equatable {
    case empty
    case emptyHost
    case invalidPort(String)
    case unbracketedIPv6
    case unterminatedBracket
    case trailingGarbage(String)
}

extension NetEndpoint {
    /// parses "1.2.3.4:1234", "host.local:1234", "[::1]:1234", "[::1]"
    /// (bracketed IPv6 with an implied default port), or a bare host/IPv4
    /// with no port (implied default). Never traps — always Result/throws.
    ///
    /// rejected: empty input, empty host, port 0, port > 65535, an
    /// unbracketed IPv6 literal (ambiguous — which colon is the port
    /// separator?), and anything with trailing garbage after a valid address.
    public static func parse(_ raw: String, defaultPort: UInt16 = NetEndpoint.defaultPort) -> Result<NetEndpoint, NetEndpointError> {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .failure(.empty) }

        if s.hasPrefix("[") {
            guard let closeIdx = s.firstIndex(of: "]") else { return .failure(.unterminatedBracket) }
            let host = String(s[s.index(after: s.startIndex)..<closeIdx])
            if host.isEmpty { return .failure(.emptyHost) }
            let rest = s[s.index(after: closeIdx)...]
            if rest.isEmpty {
                return .success(NetEndpoint(host: host, port: defaultPort))
            }
            guard rest.hasPrefix(":") else { return .failure(.trailingGarbage(String(rest))) }
            let portStr = String(rest.dropFirst())
            guard let port = parsePort(portStr) else { return .failure(.invalidPort(portStr)) }
            return .success(NetEndpoint(host: host, port: port))
        }

        let colonCount = s.reduce(0) { $0 + ($1 == ":" ? 1 : 0) }
        if colonCount > 1 {
            // an unbracketed literal with 2+ colons is an IPv6 address, which
            // is ambiguous with a host:port separator — reject, require [::1]
            return .failure(.unbracketedIPv6)
        }
        if colonCount == 1 {
            let parts = s.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let host = String(parts[0])
            let portStr = String(parts[1])
            if host.isEmpty { return .failure(.emptyHost) }
            guard let port = parsePort(portStr) else { return .failure(.invalidPort(portStr)) }
            return .success(NetEndpoint(host: host, port: port))
        }
        // bare host, no colon at all — use the default port
        return .success(NetEndpoint(host: s, port: defaultPort))
    }

    private static func parsePort(_ s: String) -> UInt16? {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard let v = Int(s), v >= 1, v <= 65535 else { return nil }
        return UInt16(v)
    }
}
