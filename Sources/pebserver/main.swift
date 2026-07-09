// pebserver — a standalone Pebble world server (SMP-style). Runs a world
// headless at 20 TPS with no host player: friends join over LAN (Bonjour)
// or the internet (direct IP), and the world keeps running until you stop it.
//
//   pebserver                          list worlds and usage
//   pebserver "My World"               serve an existing world (name or id)
//   pebserver --create "SMP" [--seed x] [--creative]
//   pebserver "My World" --port 25585
//
// Console commands while running: list, say <msg>, save, stop

import Foundation
import PebbleCore
#if os(macOS)
import PebbleNetApple
#endif

setbuf(stdout, nil)

// real LAN sockets/Bonjour instead of the portable in-memory default —
// see NetTransportDefaults in PebbleCore/Net/NetTransport.swift
#if os(macOS)
AppleNetTransportFactory.installAsDefault()
#endif

// ---- tiny arg parser --------------------------------------------------------
let rawArgs = Array(CommandLine.arguments.dropFirst())
var flags: [String: String] = [:]
var switches = Set<String>()
var positional: [String] = []
var i = 0
while i < rawArgs.count {
    let a = rawArgs[i]
    if a == "--" {
        i += 1
        continue
    }
    if a == "--creative" || a == "--help" || a == "-h" {
        switches.insert(a)
    } else if a.hasPrefix("--") {
        guard i + 1 < rawArgs.count else {
            print("error: \(a) requires a value")
            exit(2)
        }
        flags[a] = rawArgs[i + 1]
        i += 1
    } else {
        positional.append(a)
    }
    i += 1
}

let port = UInt16(flags["--port"] ?? "") ?? 25585

func usage(_ worlds: [WorldRecord]? = nil) {
    print("""
    pebserver — standalone Pebble world server (Pebble \(PEBBLE_VERSION))

      pebserver "<world name or id>" [--port \(port)] [--data-dir <path>]
      pebserver --create "<name>" [--seed <seed>] [--creative] [--port \(port)] [--data-dir <path>]
      pebserver --help

    """)
    guard let worlds else { return }
    if worlds.isEmpty {
        print("No worlds yet — create one with --create.")
    } else {
        print("Your worlds:")
        for w in worlds.sorted(by: { $0.lastPlayed > $1.lastPlayed }) {
            print("  • \(w.name)  (id \(w.id), seed \(w.seed))")
        }
    }
}

// --help must be zero-write: no GameCore, no data-dir resolution, no world list.
if switches.contains("--help") || switches.contains("-h") {
    usage()
    exit(0)
}

let explicitDataRoot: URL?
if let rawDataRoot = flags["--data-dir"] {
    let trimmed = rawDataRoot.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        print("error: --data-dir must not be empty")
        exit(2)
    }
    explicitDataRoot = URL(fileURLWithPath: trimmed)
} else {
    explicitDataRoot = nil
}
let paths: PebbleDataPaths
do {
    paths = try PebbleDataPaths.resolve(explicit: explicitDataRoot)
} catch {
    print("error: couldn't resolve data root: \(error)")
    exit(2)
}
let game = GameCore(services: .live(paths: paths))

func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}
func log(_ s: String) {
    // strip §-color codes for the console
    var out = ""
    var skip = false
    for ch in s {
        if skip { skip = false; continue }
        if ch == "§" { skip = true; continue }
        out.append(ch)
    }
    print("[\(stamp())] \(out)")
}

// ---- resolve the world ------------------------------------------------------
var record: WorldRecord?
if let createName = flags["--create"] {
    // create through the normal path (also seeds a spawn player slot for the
    // world's owner), then re-open it headless
    game.createWorld(name: createName, seedText: flags["--seed"] ?? "",
                     mode: switches.contains("--creative") ? 1 : 0, difficulty: 2)
    let id = game.worldRec?.id
    game.exitToTitle()
    record = id.flatMap { game.db.getWorld($0) }
} else if let query = positional.first {
    let all = game.listWorlds()
    record = all.first { $0.id == query }
        ?? all.first { $0.name.lowercased() == query.lowercased() }
    if record == nil {
        print("error: no world named '\(query)'\n")
        usage(all)
        exit(1)
    }
} else {
    usage(game.listWorlds())
    exit(0)
}

guard let rec = record else {
    print("error: couldn't open the world record")
    exit(1)
}

// ---- start ------------------------------------------------------------------
do {
    try game.enterWorldDedicated(rec, port: port)
} catch {
    print("error: couldn't listen on port \(port): \(error.localizedDescription)")
    exit(1)
}
game.netHost?.onLog = { line in log(line) }

let actualPortReadyUntil = Date().addingTimeInterval(5)
while (game.netHost?.port ?? 0) == 0 && Date() < actualPortReadyUntil {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
let actualPort = game.netHost?.port ?? port
print("READY port=\(actualPort) world=\(rec.id)")

log("Pebble server \(PEBBLE_VERSION) — serving '\(rec.name)' (seed \(rec.seed))")
log("Listening on port \(actualPort) — LAN players see it under 'Join LAN Game';")
log("internet players add your address in Multiplayer → Servers.")
log("Commands: list, say <message>, save, stop")

// ---- clean shutdown ---------------------------------------------------------
func shutdown() {
    log("Saving and stopping…")
    game.exitToTitle()   // shuts the session down + synchronous world save
    log("Goodbye.")
    exit(0)
}
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { shutdown() }
sigint.resume()
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { shutdown() }
sigterm.resume()

// ---- console ------------------------------------------------------------------
Thread.detachNewThread {
    while let line = readLine(strippingNewline: true) {
        DispatchQueue.main.async {
            let parts = line.split(separator: " ", maxSplits: 1)
            switch parts.first.map(String.init)?.lowercased() {
            case "stop", "exit", "quit":
                shutdown()
            case "save":
                game.saveAndFlush(synchronous: true)
                log("Saved.")
            case "list":
                let names = game.netHost?.guestNames ?? []
                log("\(names.count) player(s) online" + (names.isEmpty ? "" : ": " + names.joined(separator: ", ")))
            case "say":
                let msg = parts.count > 1 ? String(parts[1]) : ""
                if !msg.isEmpty {
                    let text = "[Server] \(msg)"
                    log(text)
                    game.netHost?.broadcastChat("§d\(text)")
                }
            case "help":
                log("Commands: list, say <message>, save, stop")
            case .none:
                break
            default:
                log("Unknown command. Try: list, say <message>, save, stop")
            }
        }
    }
}

// ---- 20 TPS loop ----------------------------------------------------------------
var lastTick = CFAbsoluteTimeGetCurrent()
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
timer.setEventHandler {
    let now = CFAbsoluteTimeGetCurrent()
    let dt = (now - lastTick) * 1000
    lastTick = now
    _ = game.frame(dtMs: dt)
}
timer.resume()

RunLoop.main.run()
