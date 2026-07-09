// Deterministic-only selected smoke for portable CI.
// Deliberately does not import PebbleCore, GameCore, storage, network, app, or resources.

import Foundation
import PebbleCoreBase

let env = ProcessInfo.processInfo.environment
let inCI = env["PEBBLE_CI"] == "1" || env["CI"] != nil || env["GITHUB_ACTIONS"] != nil
if inCI && env["PEBBLE_REGOLD"] != nil {
    FileHandle.standardError.write(Data("error: PEBBLE_REGOLD is forbidden in CI\n".utf8))
    exit(2)
}

var requestedSuites = Set<String>()
var requiredSuites = Set<String>()
var reportPath: String?
var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let arg = args[i]
    switch arg {
    case "--":
        break
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
    case "--help", "-h":
        print("""
        pebsmoke-deterministic — portable deterministic smoke

          --suite deterministic
          --require-suite deterministic
          --report-json <path>
        """)
        exit(0)
    default:
        FileHandle.standardError.write(Data("error: unknown argument \(arg)\n".utf8))
        exit(2)
    }
    i += 1
}

let allowedSuites: Set<String> = ["deterministic"]
let suitesToRun = requestedSuites.isEmpty ? allowedSuites : requestedSuites
let unknown = suitesToRun.subtracting(allowedSuites).union(requiredSuites.subtracting(allowedSuites))
if !unknown.isEmpty {
    FileHandle.standardError.write(Data("error: unsupported deterministic smoke suite(s): \(unknown.sorted().joined(separator: ", "))\n".utf8))
    exit(2)
}

var passed = 0
var failed = 0
var checks = 0

func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    checks += 1
    if cond {
        passed += 1
        print("  ✓ \(name)")
    } else {
        failed += 1
        print("  ✗ \(name) \(detail)")
    }
}

func checkD(_ name: String, _ got: Double, _ want: Double, tol: Double = 1e-12) {
    check(name, abs(got - want) <= tol, "got \(got) want \(want)")
}

func section(_ name: String) { print("\n— \(name)") }

if suitesToRun.contains("deterministic") {
    section("random")
    check("hashString abc", hashString("abc") == 440920331, "got \(hashString("abc"))")
    check("mix32 12345", mix32(12345) == 1011272156, "got \(mix32(12345))")
    check("hash2", hash2(999, -1234, 5678, 7) == 1511826033, "got \(hash2(999, -1234, 5678, 7))")
    check("hash3", hash3(999, -12, 34, -56, 3) == 2031202406, "got \(hash3(999, -12, 34, -56, 3))")

    var r = RandomX(12345)
    let golden12345: [UInt32] = [1009662611, 487413528, 3278825217, 2736101217, 2510057557, 1701016183, 572264801, 2565169478]
    var seqOK = true
    for want in golden12345 where r.next() != want { seqOK = false }
    check("sfc32 seed 12345 sequence", seqOK)

    var r2 = RandomX(0xDEAD_BEEF)
    let goldenDB: [UInt32] = [1504311087, 3087835436, 4013932724, 864736003]
    var seq2OK = true
    for want in goldenDB where r2.next() != want { seq2OK = false }
    check("sfc32 seed 0xDEADBEEF sequence", seq2OK)

    var r3 = RandomX(777)
    var inRange = true
    for _ in 0..<1000 {
        let v = r3.nextInt(10)
        if v < 0 || v >= 10 { inRange = false }
    }
    check("nextInt bounds", inRange)

    section("simplex noise")
    let n = SimplexNoise(42)
    checkD("noise2 (0.5,0.5)", n.noise2(0.5, 0.5), -0.30780618346945793)
    checkD("noise2 (10.25,-3.75)", n.noise2(10.25, -3.75), 0)
    checkD("noise2 (100.1,200.9)", n.noise2(100.1, 200.9), -0.6225765639891507)
    checkD("noise2 (-55.5,17.3)", n.noise2(-55.5, 17.3), 0.4811125458747653)
    checkD("noise3 (1.5,2.5,3.5)", n.noise3(1.5, 2.5, 3.5), 0)
    checkD("noise3 (-10.1,40.2,-7.7)", n.noise3(-10.1, 40.2, -7.7), 0.12712837501423255)

    let f = FBM(7, 4, 0.01)
    checkD("fbm sample2 (123.4,567.8)", f.sample2(123.4, 567.8), -0.17945870068084002)
    checkD("fbm ridge2 (123.4,567.8)", f.ridge2(123.4, 567.8), 0.4321547307883241)
    checkD("fbm sample2 (-1000.5,250.25)", f.sample2(-1000.5, 250.25), -0.37532916362726393)
    checkD("fbm ridge2 (-1000.5,250.25)", f.ridge2(-1000.5, 250.25), 0.41162552326329793)

    let sp = Spline([(0, 0), (0.5, 10), (1, 4)])
    checkD("spline at -1", sp.at(-1), 0)
    checkD("spline at 0.25", sp.at(0.25), 5)
    checkD("spline at 0.5", sp.at(0.5), 10)
    checkD("spline at 0.75", sp.at(0.75), 7)
    checkD("spline at 2", sp.at(2), 4)

    section("deterministic trig and dirs")
    checkD("detSin 0", detSin(0), 0)
    checkD("detCos 0", detCos(0), 1)
    checkD("detSin pi/2", detSin(.pi / 2), 1, tol: 1e-11)
    checkD("detCos pi", detCos(.pi), -1, tol: 1e-11)
    checkD("detAtan2 1,1", detAtan2(1, 1), .pi / 4, tol: 1e-11)
    check("Dir opposite north/south", DIR_OPPOSITE[Dir.north] == Dir.south)
    check("yaw south", yawToDir(0) == Dir.south)
    check("yaw west", yawToDir(90) == Dir.west)
    check("yaw north", yawToDir(180) == Dir.north)
    check("yaw east", yawToDir(270) == Dir.east)
}

for required in requiredSuites where !suitesToRun.contains(required) {
    failed += 1
    print("  ✗ required suite missing \(required)")
}
if checks == 0 {
    failed += 1
    print("  ✗ no checks executed")
}

let status = [
    "suite": "deterministic",
    "checks": checks,
    "passed": passed,
    "failed": failed,
    "dataDir": env["PEBBLE_DATA_DIR"] ?? "",
    "goldensDir": env["PEBBLE_GOLDENS_DIR"] ?? "",
] as [String: Any]

if let reportPath {
    let data = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
