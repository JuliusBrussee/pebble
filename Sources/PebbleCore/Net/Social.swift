// Friends, saved servers, recent players — Pebble has no central account
// service, so all of this lives in JSON files next to the settings. Identity
// is the permanent `playerId` UUID from Settings (XUID-style: names change,
// the id doesn't). "Online" presence comes from Bonjour: a friend is joinable
// when a discovered session's TXT record carries their id.

import Foundation

public struct FriendEntry: Codable, Equatable {
    public var id: String
    public var name: String        // last name we saw them use
    public var lastSeen: Double    // ms epoch
    public init(id: String, name: String, lastSeen: Double = Date().timeIntervalSince1970 * 1000) {
        self.id = id
        self.name = name
        self.lastSeen = lastSeen
    }
}

public struct ServerEntry: Codable, Equatable {
    public var name: String
    public var host: String        // hostname or IP
    public var port: UInt16
    public init(name: String, host: String, port: UInt16) {
        self.name = name
        self.host = host
        self.port = port
    }
}

/// everyone you've shared a world with — the pool you promote friends from
public struct RecentPlayer: Codable, Equatable {
    public var id: String
    public var name: String
    public var lastSeen: Double    // ms epoch
    public var how: String         // "joined you" | "you joined" | "on server"
    public init(id: String, name: String, how: String,
                lastSeen: Double = Date().timeIntervalSince1970 * 1000) {
        self.id = id
        self.name = name
        self.how = how
        self.lastSeen = lastSeen
    }
}

private func socialURL(_ file: String) -> URL {
    vcSupportDir().appendingPathComponent(file)
}

private func loadJSON<T: Codable>(_ file: String, _ fallback: T) -> T {
    guard let data = try? Data(contentsOf: socialURL(file)),
          let v = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
    return v
}

private func saveJSON<T: Codable>(_ file: String, _ v: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(v) {
        try? data.write(to: socialURL(file), options: .atomic)
    }
}

/// Friend codes — your permanent identity packed into a short, shareable
/// string ("PEB1…"). No accounts, no cloud: swapping codes over any chat app
/// IS the friend request + accept. Encodes the 16 UUID bytes + display name.
public enum FriendCode {
    public static func encode(pid: String, name: String) -> String? {
        guard let uuid = UUID(uuidString: pid) else { return nil }
        var data = withUnsafeBytes(of: uuid.uuid) { Data($0) }
        data.append(Data(String(name.prefix(12)).utf8))
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "PEB1" + b64
    }

    public static func decode(_ raw: String) -> (pid: String, name: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("PEB1") else { return nil }
        var b64 = String(trimmed.dropFirst(4))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), data.count >= 16 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        data.copyBytes(to: &bytes, count: 16)
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        let name = String(data: data.dropFirst(16), encoding: .utf8) ?? ""
        return (uuid.uuidString, name.isEmpty ? "Friend" : name)
    }
}

/// one shared store, loaded lazily, saved on every mutation (tiny files)
public final class SocialStore {
    public static let shared = SocialStore()

    public private(set) var friends: [FriendEntry]
    public private(set) var servers: [ServerEntry]
    public private(set) var recents: [RecentPlayer]

    private init() {
        friends = loadJSON("friends.json", [])
        servers = loadJSON("servers.json", [])
        recents = loadJSON("recents.json", [])
    }

    // ---- friends ----
    public func isFriend(_ id: String) -> Bool {
        friends.contains { $0.id == id }
    }
    public func addFriend(id: String, name: String) {
        guard !id.isEmpty else { return }
        if let i = friends.firstIndex(where: { $0.id == id }) {
            friends[i].name = name
            friends[i].lastSeen = Date().timeIntervalSince1970 * 1000
        } else {
            friends.append(FriendEntry(id: id, name: name))
        }
        saveJSON("friends.json", friends)
    }
    public func removeFriend(id: String) {
        friends.removeAll { $0.id == id }
        saveJSON("friends.json", friends)
    }
    /// met them again — refresh name + last-seen if they're a friend
    public func touchFriend(id: String, name: String) {
        guard let i = friends.firstIndex(where: { $0.id == id }) else { return }
        friends[i].name = name
        friends[i].lastSeen = Date().timeIntervalSince1970 * 1000
        saveJSON("friends.json", friends)
    }

    // ---- servers ----
    public func addServer(_ s: ServerEntry) {
        if let i = servers.firstIndex(where: { $0.host == s.host && $0.port == s.port }) {
            servers[i] = s
        } else {
            servers.append(s)
        }
        saveJSON("servers.json", servers)
    }
    public func removeServer(host: String, port: UInt16) {
        servers.removeAll { $0.host == host && $0.port == port }
        saveJSON("servers.json", servers)
    }

    // ---- recent players ----
    public func removeRecent(id: String) {
        recents.removeAll { $0.id == id }
        saveJSON("recents.json", recents)
    }
    public func recordRecent(id: String, name: String, how: String) {
        guard !id.isEmpty else { return }
        recents.removeAll { $0.id == id }
        recents.insert(RecentPlayer(id: id, name: name, how: how), at: 0)
        if recents.count > 20 { recents.removeLast(recents.count - 20) }
        saveJSON("recents.json", recents)
        touchFriend(id: id, name: name)
    }
}
