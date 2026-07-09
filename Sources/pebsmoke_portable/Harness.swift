// shared check-counting harness for portable smoke suites.

public struct SmokeHarness {
    public private(set) var checks = 0
    public private(set) var failures: [String] = []

    public init() {}

    public mutating func check(_ name: String, _ ok: Bool) {
        checks += 1
        if !ok { failures.append(name) }
    }

    public mutating func eq<T: Equatable>(_ name: String, _ a: T, _ b: T) {
        check(name, a == b)
    }
}

public protocol PortableSuite {
    static var name: String { get }
    static func run(_ h: inout SmokeHarness)
}
