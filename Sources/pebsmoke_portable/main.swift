// Portable smoke harness: fail-closed CLI mirroring pebsmoke_deterministic's shape,
// but running the wider set of portable suites (math, vck1, protocol, persistence,
// renderabi, codecs, audio, sockets). Suites not yet implemented by a lane run zero
// checks by design — requiring them with --require-suite is meant to fail today.

import Foundation
import PebbleCoreBase
import CPebblePlatform
import PebblePlatformNative
import PebbleRenderABI
import PebbleCodecs
import PebbleAudioCore
import PebbleCore

let env = ProcessInfo.processInfo.environment
let inCI = env["PEBBLE_CI"] == "1" || env["CI"] != nil || env["GITHUB_ACTIONS"] != nil
if inCI && env["PEBBLE_REGOLD"] != nil {
    FileHandle.standardError.write(Data("error: PEBBLE_REGOLD is forbidden in CI\n".utf8))
    exit(2)
}

let allSuites: [any PortableSuite.Type] = [
    MathSuite.self,
    Vck1Suite.self,
    ProtocolSuite.self,
    PersistenceSuite.self,
    RenderABISuite.self,
    CodecsSuite.self,
    AudioSuite.self,
    SocketsSuite.self,
]
let allSuiteNames = Set(allSuites.map { $0.name })

var requestedSuites = Set<String>()
var requiredSuites = Set<String>()
var reportPath: String?
var dataRoot: String?
var goldensDir: String?

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let arg = args[i]
    switch arg {
    case "--suite":
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("error: --suite requires a value\n".utf8))
            exit(2)
        }
        requestedSuites.insert(args[i + 1])
        i += 1
    case "--require-suite":
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("error: --require-suite requires a value\n".utf8))
            exit(2)
        }
        requiredSuites.insert(args[i + 1])
        i += 1
    case "--report-json":
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("error: --report-json requires a value\n".utf8))
            exit(2)
        }
        reportPath = args[i + 1]
        i += 1
    case "--data-root":
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("error: --data-root requires a value\n".utf8))
            exit(2)
        }
        dataRoot = args[i + 1]
        i += 1
    case "--goldens-dir":
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("error: --goldens-dir requires a value\n".utf8))
            exit(2)
        }
        goldensDir = args[i + 1]
        i += 1
    case "--help", "-h":
        print("""
        pebsmoke-portable — portable (non-Apple-framework) smoke harness

          --suite <name>            run one suite (repeatable); default: all
          --require-suite <name>    fail closed (exit 3) unless <name> ran and had > 0 checks
          --report-json <path>      write a JSON summary
          --data-root <path>        injected data root for suites that touch storage
          --goldens-dir <path>      injected goldens directory
          --help                    this message

        suites: \(allSuiteNames.sorted().joined(separator: ", "))
        """)
        exit(0)
    default:
        FileHandle.standardError.write(Data("error: unknown argument \(arg)\n".utf8))
        exit(2)
    }
    i += 1
}

let suitesToRun = requestedSuites.isEmpty ? allSuiteNames : requestedSuites
let unknownRequested = suitesToRun.subtracting(allSuiteNames)
if !unknownRequested.isEmpty {
    FileHandle.standardError.write(Data("error: unknown suite(s): \(unknownRequested.sorted().joined(separator: ", "))\n".utf8))
    exit(2)
}

var checksBySuite: [String: Int] = [:]
var failuresBySuite: [String: Int] = [:]
var totalChecks = 0
var totalFailures = 0

for suite in allSuites where suitesToRun.contains(suite.name) {
    var h = SmokeHarness()
    suite.run(&h)
    checksBySuite[suite.name] = h.checks
    failuresBySuite[suite.name] = h.failures.count
    totalChecks += h.checks
    totalFailures += h.failures.count
    print("suite=\(suite.name) checks=\(h.checks) failures=\(h.failures.count)")
    for f in h.failures {
        print("  ✗ \(f)")
    }
}

// fail closed: a required suite must be a known suite AND must have run at least one check.
var requireFailed = false
for required in requiredSuites {
    if !allSuiteNames.contains(required) {
        FileHandle.standardError.write(Data("error: --require-suite names unknown suite \(required)\n".utf8))
        requireFailed = true
        continue
    }
    if (checksBySuite[required] ?? 0) == 0 {
        FileHandle.standardError.write(Data("error: required suite \(required) ran zero checks\n".utf8))
        requireFailed = true
    }
}

let status: [String: Any] = [
    "suites": suitesToRun.sorted(),
    "checksBySuite": checksBySuite,
    "failuresBySuite": failuresBySuite,
    "totalChecks": totalChecks,
    "totalFailures": totalFailures,
    "dataRoot": dataRoot ?? "",
    "goldensDir": goldensDir ?? "",
]
if let reportPath {
    if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
    }
}

print("\n\(totalChecks) checks, \(totalFailures) failures")

if requireFailed {
    exit(3)
}
exit(totalFailures == 0 ? 0 : 1)
