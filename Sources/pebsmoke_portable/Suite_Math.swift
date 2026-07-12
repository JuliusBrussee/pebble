import Foundation
import PebbleCoreBase
import PebbleCore

public struct MathSuite: PortableSuite {
    public static let name = "math"

    public static func run(_ h: inout SmokeHarness) {
        h.eq("hypotenuse 3-4-5", PebbleCoreBase.detHyp(3, 4), 5)
        h.eq("three-axis hypotenuse", PebbleCoreBase.detHyp3(2, 3, 6), 7)
        h.check("sin/cos identity", abs(PebbleCoreBase.detSin(0.75) * PebbleCoreBase.detSin(0.75) + PebbleCoreBase.detCos(0.75) * PebbleCoreBase.detCos(0.75) - 1) < 1e-12)
        h.check("atan2 quadrant II", abs(PebbleCoreBase.detAtan2(1, -1) - 3 * Double.pi / 4) < 1e-12)
        h.eq("yaw wraps negative", PebbleCoreBase.yawToDir(-90), PebbleCoreBase.Dir.east)

        let manual = PebbleCoreBase.ManualMonotonicClock(seconds: 4)
        h.eq("manual clock initial value", manual.nowSeconds(), 4)
        manual.advance(by: 1.25)
        h.eq("manual clock advances", manual.nowSeconds(), 5.25)
        manual.set(seconds: 2)
        h.eq("manual clock refuses backwards set", manual.nowSeconds(), 5.25)
        manual.set(seconds: 8)
        h.eq("manual clock accepts forwards set", manual.nowSeconds(), 8)

        let identity = PebbleCore.mat4Identity()
        h.eq("identity diagonal 0", identity[0], SIMD4<Float>(1, 0, 0, 0))
        h.eq("identity diagonal 3", identity[3], SIMD4<Float>(0, 0, 0, 1))
        let translated = PebbleCore.mat4Translate(identity, 2, -3, 4)
        h.eq("translation column", translated[3], SIMD4<Float>(2, -3, 4, 1))
        h.eq("left identity multiplication", identity * translated, translated)
        h.eq("right identity multiplication", translated * identity, translated)

        let box = PebbleCore.AABB(0, 0, 0, 1, 1, 1)
        h.check("aabb intersects overlap", box.intersects(PebbleCore.AABB(0.5, 0.5, 0.5, 2, 2, 2)))
        h.check("aabb excludes touching face", !box.intersects(PebbleCore.AABB(1, 0, 0, 2, 1, 1)))
        h.eq("vector cross product", PebbleCore.vCross(PebbleCore.Vec3(1, 0, 0), PebbleCore.Vec3(0, 1, 0)), PebbleCore.Vec3(0, 0, 1))
    }
}
