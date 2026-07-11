import Foundation

/// Monotonic time source for simulation budgets and elapsed-time measurement.
/// Values have no wall-clock epoch and never move backwards.
public protocol MonotonicClock: Sendable {
    func nowSeconds() -> Double
}

public struct SystemMonotonicClock: MonotonicClock {
    public init() {}

    public func nowSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

/// Deterministic mutable clock for replay, server stepping, and embedding.
public final class ManualMonotonicClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double

    public init(seconds: Double = 0) {
        value = seconds
    }

    public func nowSeconds() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func set(seconds: Double) {
        lock.lock()
        value = max(value, seconds)
        lock.unlock()
    }

    public func advance(by seconds: Double) {
        precondition(seconds >= 0, "monotonic clock cannot move backwards")
        lock.lock()
        value += seconds
        lock.unlock()
    }
}
