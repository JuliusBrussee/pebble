// Multiplayer — one screen, three tabs:
//   LAN Games — Bonjour-discovered sessions on this network, click to join
//   Friends   — your friends list (online = joinable, via TXT pid match)
//               plus Recent Players you can promote to friends
//   Servers   — saved addresses for standalone pebserver worlds (SMP);
//               works across the internet with a port-forwarded host
// Identity is Settings.playerId (permanent); the name field is display-only.

import AppKit
import Foundation
import Network
import PebbleCore

final class MultiplayerScreen: Screen {
    let nameField = TextField(0, 0, 200, 16, "Your name")
    let addressField = TextField(0, 0, 200, 16, "address, like 192.168.1.20:25585")
    let serverNameField = TextField(0, 0, 200, 16, "name this server")
    let codeField = TextField(0, 0, 200, 16, "paste a friend code (PEB1…)")

    private var tab = "lan"
    private let browser = NetBrowser()
    private var found: [NetBrowser.Found] = []
    private var status = ""
    private var statusColor = "#a0a0a0"
    private var joining: NetGuestSession?
    private weak var ui: UIManager?
    private weak var game: GameCore?

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        self.ui = ui
        self.game = game
        nameField.text = game.settings.playerName ?? ""
        browser.onUpdate = { [weak self] results in
            guard let self, let ui = self.ui, let game = self.game else { return }
            self.found = results
            self.rebuild(ui, game)
        }
        browser.start()
        rebuild(ui, game)
    }

    private func saveName(_ game: GameCore) -> String {
        var name = nameField.text.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Player" }
        if game.settings.playerName != name {
            game.settings.playerName = name
            game.applySettings()
        }
        return name
    }

    /// the discovered session (if any) hosted by this friend right now
    private func sessionOf(_ friendId: String) -> NetBrowser.Found? {
        guard !friendId.isEmpty else { return nil }
        return found.first { $0.txt["pid"] == friendId }
    }

    private func rebuild(_ ui: UIManager, _ game: GameCore) {
        buttons = []
        fields = []
        let cx = (ui.width / 2).rounded(.down)

        // tabs
        for (i, t) in [("lan", "LAN Games"), ("friends", "Friends"), ("servers", "Servers")].enumerated() {
            let b = Button(cx - 160 + Double(i) * 108, 20, 104, 16, t.1, {})
            b.enabled = tab != t.0
            b.onClick = { [weak self, weak ui, weak game] in
                guard let self, let ui, let game else { return }
                self.tab = t.0
                self.status = ""
                self.rebuild(ui, game)
            }
            buttons.append(b)
        }

        nameField.x = cx - 100
        nameField.y = 56
        fields.append(nameField)
        var y = 96.0

        switch tab {
        case "lan":
            if found.isEmpty {
                status = joining == nil ? "Searching for games on this network…" : status
            } else if joining == nil {
                status = "\(found.count) game\(found.count == 1 ? "" : "s") found — click to join"
                statusColor = "#a0a0a0"
            }
            for f in found.prefix(6) {
                let label = f.txt["srv"] == "1" ? "§d[Server]§r \(f.name)" : f.name
                let b = Button(cx - 100, y, 200, 20, label, { [weak self] in
                    self?.join(f.endpoint, shownName: f.name)
                })
                b.enabled = joining == nil
                buttons.append(b)
                y += 24
            }

        case "friends":
            // your code + paste-a-code: swap codes over any chat app = friends
            let copyB = Button(cx - 100, y, 98, 20, "Copy My Code", { [weak self, weak game] in
                guard let self, let game else { return }
                let name = self.saveName(game)
                if let code = FriendCode.encode(pid: game.settings.playerId ?? "", name: name) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    self.status = "Code copied! Send it to your friend (WhatsApp, anything)."
                    self.statusColor = "#a0ffa0"
                }
            })
            buttons.append(copyB)
            codeField.x = cx - 100
            codeField.y = y + 26
            codeField.maxLength = 120
            fields.append(codeField)
            let addB = Button(cx + 2, y, 98, 20, "Add By Code", { [weak self, weak ui, weak game] in
                guard let self, let ui, let game else { return }
                guard let decoded = FriendCode.decode(self.codeField.text) else {
                    self.status = "Hmm, that doesn't look like a friend code."
                    self.statusColor = "#ff7070"
                    return
                }
                if decoded.pid == game.settings.playerId {
                    self.status = "That's your OWN code — send it to your friend instead!"
                    self.statusColor = "#ffff55"
                    return
                }
                game.socialStore.addFriend(id: decoded.pid, name: decoded.name)
                self.codeField.text = ""
                self.codeField.caret = 0
                self.status = "\(decoded.name) added! Now send them YOUR code too."
                self.statusColor = "#a0ffa0"
                self.rebuild(ui, game)
            })
            buttons.append(addB)
            y += 52

            let friends = game.socialStore.friends
            if friends.isEmpty {
                status = "No friends yet — swap friend codes, or play together once!"
                statusColor = "#a0a0a0"
            }
            for fr in friends.prefix(4) {
                let live = sessionOf(fr.id)
                let label = live != nil
                    ? "§a●§r \(fr.name) — playing §f\(live!.txt["world"] ?? "a world")"
                    : "§8●§r \(fr.name) — offline"
                let joinB = Button(cx - 130, y, 200, 20, label, { [weak self] in
                    if let live { self?.join(live.endpoint, shownName: fr.name) }
                })
                joinB.enabled = live != nil && joining == nil
                buttons.append(joinB)
                let removeB = Button(cx + 74, y, 20, 20, "§c✕", { [weak self, weak ui, weak game] in
                    guard let self, let ui, let game else { return }
                    game.socialStore.removeFriend(id: fr.id)
                    self.rebuild(ui, game)
                })
                buttons.append(removeB)
                y += 24
            }
            // recent players → add as friend
            let candidates = game.socialStore.recents.filter { !game.socialStore.isFriend($0.id) }
            if !candidates.isEmpty {
                y += 14
                for rp in candidates.prefix(2) {
                    let b = Button(cx - 100, y, 200, 20, "§e+ Add friend:§r \(rp.name) (\(rp.how))", {
                        [weak self, weak ui, weak game] in
                        guard let self, let ui, let game else { return }
                        game.socialStore.addFriend(id: rp.id, name: rp.name)
                        self.status = "\(rp.name) added!"
                        self.statusColor = "#a0ffa0"
                        self.rebuild(ui, game)
                    })
                    buttons.append(b)
                    y += 24
                }
            }

        case "servers":
            let servers = game.socialStore.servers
            if servers.isEmpty && status.isEmpty {
                status = "Save a server address below (ask the server owner for it)."
                statusColor = "#a0a0a0"
            }
            for s in servers.prefix(4) {
                let joinB = Button(cx - 130, y, 200, 20, "\(s.name) §7(\(s.host):\(s.port))", { [weak self] in
                    self?.joinAddress(s.host, s.port, shownName: s.name)
                })
                joinB.enabled = joining == nil
                buttons.append(joinB)
                let removeB = Button(cx + 74, y, 20, 20, "§c✕", { [weak self, weak ui, weak game] in
                    guard let self, let ui, let game else { return }
                    game.socialStore.removeServer(host: s.host, port: s.port)
                    self.rebuild(ui, game)
                })
                buttons.append(removeB)
                y += 24
            }
            y += 14
            addressField.x = cx - 100
            addressField.y = y + 10
            fields.append(addressField)
            serverNameField.x = cx - 100
            serverNameField.y = y + 46
            fields.append(serverNameField)
            let addB = Button(cx - 100, y + 68, 98, 20, "Save Server", { [weak self, weak ui, weak game] in
                guard let self, let ui, let game else { return }
                if let entry = self.parseAddress() {
                    game.socialStore.addServer(entry)
                    self.status = "Saved \(entry.name)."
                    self.statusColor = "#a0ffa0"
                    self.addressField.text = ""
                    self.serverNameField.text = ""
                    self.rebuild(ui, game)
                }
            })
            let connectB = Button(cx + 2, y + 68, 98, 20, "Connect", { [weak self] in
                guard let self, let entry = self.parseAddress() else { return }
                self.joinAddress(entry.host, entry.port, shownName: entry.name)
            })
            buttons.append(addB)
            buttons.append(connectB)

        default:
            break
        }

        buttons.append(Button(cx - 100, ui.height - 30, 200, 20, "Cancel", { [weak self, weak ui, weak game] in
            guard let ui, let game else { return }
            self?.abortJoin()
            ui.closeTop(game)
        }))
    }

    private func parseAddress() -> ServerEntry? {
        let raw = addressField.text.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else {
            status = "Type a server address first (like 84.25.10.3:25585)."
            statusColor = "#ff7070"
            return nil
        }
        let parts = raw.split(separator: ":", maxSplits: 1)
        let host = String(parts[0])
        let port = parts.count > 1 ? UInt16(parts[1]) ?? 25585 : 25585
        var name = serverNameField.text.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = host }
        return ServerEntry(name: name, host: host, port: port)
    }

    private func join(_ endpoint: NWEndpoint, shownName: String) {
        guard let game, joining == nil else { return }
        let name = saveName(game)
        status = "Joining \(shownName)…"
        statusColor = "#ffff55"
        let skin = (try? Data(contentsOf: customSkinURL)) ?? Data()
        joining = game.joinLan(netDial(endpoint), name: name, skin: skin)
        if let ui { rebuild(ui, game) }
    }

    private func joinAddress(_ host: String, _ port: UInt16, shownName: String) {
        guard let game, joining == nil else { return }
        let name = saveName(game)
        status = "Connecting to \(shownName)…"
        statusColor = "#ffff55"
        let skin = (try? Data(contentsOf: customSkinURL)) ?? Data()
        joining = game.joinLan(netDial(host: host, port: port), name: name, skin: skin)
        if let ui { rebuild(ui, game) }
    }

    private func abortJoin() {
        browser.stop()
        if let j = joining, let game, !game.hasWorld() {
            game.netGuest = nil
            j.shutdown()
        }
        joining = nil
    }

    override func onClose(_ ui: UIManager, _ game: GameCore) {
        browser.stop()
    }

    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDirtBg()
        ui.cv.drawTextCentered("Multiplayer", ui.width / 2, 6, 1)
        ui.cv.drawText("Your Name", nameField.x, nameField.y - 10, 1, "#a0a0a0")
        if tab == "servers" && fields.count > 1 {
            ui.cv.drawText("Server Address", addressField.x, addressField.y - 10, 1, "#a0a0a0")
            ui.cv.drawText("Server Name (optional)", serverNameField.x, serverNameField.y - 10, 1, "#a0a0a0")
        }
        if let j = joining, !j.joined, j.status != "connecting…", j.status != "joined" {
            status = j.status
            statusColor = "#ff7070"
            if game.netGuest == nil {
                joining = nil
                rebuild(ui, game)
            }
        }
        if !status.isEmpty {
            ui.cv.drawTextCentered(status, ui.width / 2, 82, 1, statusColor)
        }
        if tab == "lan" && found.isEmpty && joining == nil {
            ui.cv.drawTextCentered("§7Ask the host to press Esc → \"Open to LAN\" in their world,", ui.width / 2, 120, 1)
            ui.cv.drawTextCentered("§7or start a server with:  pebble serve", ui.width / 2, 134, 1)
        }
        ui.drawButtons(self)
    }
}
