// Math utilities: scalars, Vec3 (Double, for sim), Mat4 (Float, Metal clip
// space z∈[0,1]), AABB with axis sweeps, frustum. Includes
// the projection/frustum forms adjusted from GL to Metal conventions.

import Foundation

// ---- scalars -----------------------------------------------------------------
@inline(__always) public func clampD(_ x: Double, _ lo: Double, _ hi: Double) -> Double { x < lo ? lo : (x > hi ? hi : x) }
@inline(__always) public func clampF(_ x: Float, _ lo: Float, _ hi: Float) -> Float { x < lo ? lo : (x > hi ? hi : x) }
@inline(__always) public func lerpD(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
@inline(__always) public func lerpF(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) public func smoothstepD(_ t: Double) -> Double { t * t * (3 - 2 * t) }
@inline(__always) public func smootherstepD(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }
@inline(__always) public func degToRad(_ d: Double) -> Double { d * .pi / 180 }
@inline(__always) public func radToDeg(_ r: Double) -> Double { r * 180 / .pi }

public func wrapDegrees(_ input: Double) -> Double {
    var d = input.truncatingRemainder(dividingBy: 360)
    if d >= 180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
}

public func approachDegrees(_ cur: Double, _ target: Double, _ maxStep: Double) -> Double {
    let delta = wrapDegrees(target - cur)
    return cur + clampD(delta, -maxStep, maxStep)
}

@inline(__always)
public func mapRange(_ x: Double, _ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
    b0 + (b1 - b0) * clampD((x - a0) / (a1 - a0), 0, 1)
}

public func easeOutCubic(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
public func easeInOutQuad(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }

// ---- Vec3 (Double — simulation space) -----------------------------------------
public typealias Vec3 = SIMD3<Double>

@inline(__always) public func vec3(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) -> Vec3 { Vec3(x, y, z) }
@inline(__always) public func vLenSq(_ a: Vec3) -> Double { a.x * a.x + a.y * a.y + a.z * a.z }
@inline(__always) public func vLen(_ a: Vec3) -> Double { sqrt(vLenSq(a)) }
@inline(__always) public func vDistSq(_ a: Vec3, _ b: Vec3) -> Double { vLenSq(a - b) }
@inline(__always) public func vDist(_ a: Vec3, _ b: Vec3) -> Double { sqrt(vDistSq(a, b)) }
@inline(__always) public func vDot(_ a: Vec3, _ b: Vec3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
@inline(__always) public func vCross(_ a: Vec3, _ b: Vec3) -> Vec3 {
    Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
@inline(__always) public func vLerp(_ a: Vec3, _ b: Vec3, _ t: Double) -> Vec3 { a + (b - a) * t }

@inline(__always)
public func vNorm(_ a: Vec3) -> Vec3 {
    let l = vLen(a)
    return l < 1e-9 ? Vec3() : a / l
}

// ---- Mat4 (Float, column-major, Metal clip space) ------------------------------
public struct Mat4f: Equatable, Sendable {
    public var columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

    public init(_ diagonal: Float = 0) {
        columns = (
            SIMD4<Float>(diagonal, 0, 0, 0),
            SIMD4<Float>(0, diagonal, 0, 0),
            SIMD4<Float>(0, 0, diagonal, 0),
            SIMD4<Float>(0, 0, 0, diagonal)
        )
    }

    public init(columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)) {
        self.columns = columns
    }

    public subscript(_ column: Int) -> SIMD4<Float> {
        get {
            switch column {
            case 0: return columns.0
            case 1: return columns.1
            case 2: return columns.2
            case 3: return columns.3
            default: preconditionFailure("Mat4f column out of range: \(column)")
            }
        }
        set {
            switch column {
            case 0: columns.0 = newValue
            case 1: columns.1 = newValue
            case 2: columns.2 = newValue
            case 3: columns.3 = newValue
            default: preconditionFailure("Mat4f column out of range: \(column)")
            }
        }
    }

    public static func == (lhs: Mat4f, rhs: Mat4f) -> Bool {
        lhs.columns.0 == rhs.columns.0 && lhs.columns.1 == rhs.columns.1 &&
        lhs.columns.2 == rhs.columns.2 && lhs.columns.3 == rhs.columns.3
    }

    public static func * (lhs: Mat4f, rhs: Mat4f) -> Mat4f {
        func transform(_ vector: SIMD4<Float>) -> SIMD4<Float> {
            lhs[0] * vector.x + lhs[1] * vector.y + lhs[2] * vector.z + lhs[3] * vector.w
        }
        return Mat4f(columns: (transform(rhs[0]), transform(rhs[1]),
                               transform(rhs[2]), transform(rhs[3])))
    }
}

public typealias Mat4 = Mat4f

public func mat4Identity() -> Mat4 { Mat4(1) }

/// perspective with Metal depth range z' ∈ [0, 1]
public func mat4Perspective(fovYRad: Float, aspect: Float, near: Float, far: Float) -> Mat4 {
    let f = 1 / tan(fovYRad / 2)
    var m = Mat4(0)
    m[0][0] = f / aspect
    m[1][1] = f
    m[2][2] = far / (near - far)
    m[2][3] = -1
    m[3][2] = (far * near) / (near - far)
    return m
}

/// ortho with Metal depth range z' ∈ [0, 1]
public func mat4Ortho(l: Float, r: Float, b: Float, t: Float, n: Float, f: Float) -> Mat4 {
    var m = Mat4(0)
    m[0][0] = 2 / (r - l)
    m[1][1] = 2 / (t - b)
    m[2][2] = -1 / (f - n)
    m[3][0] = -(r + l) / (r - l)
    m[3][1] = -(t + b) / (t - b)
    m[3][2] = -n / (f - n)
    m[3][3] = 1
    return m
}

public func mat4LookDir(eye: SIMD3<Float>, dir: SIMD3<Float>, up: SIMD3<Float>) -> Mat4 {
    func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x * b.x + a.y * b.y + a.z * b.z }
    func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
    func normalized(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let length = sqrt(dot(v, v))
        return length > 0 ? v / length : .zero
    }
    let z = normalized(-dir)
    let x = normalized(cross(up, z))
    let y = cross(z, x)
    return Mat4(columns: (
        SIMD4<Float>(x.x, y.x, z.x, 0),
        SIMD4<Float>(x.y, y.y, z.y, 0),
        SIMD4<Float>(x.z, y.z, z.z, 0),
        SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
    ))
}

public func mat4Translate(_ m: Mat4, _ x: Float, _ y: Float, _ z: Float) -> Mat4 {
    var out = m
    out[3] = m[0] * x + m[1] * y + m[2] * z + m[3]
    return out
}

public func mat4Scale(_ m: Mat4, _ x: Float, _ y: Float, _ z: Float) -> Mat4 {
    var out = m
    out[0] = m[0] * x
    out[1] = m[1] * y
    out[2] = m[2] * z
    return out
}

public func mat4RotateX(_ m: Mat4, _ rad: Float) -> Mat4 {
    let s = sin(rad), c = cos(rad)
    var out = m
    out[1] = m[1] * c + m[2] * s
    out[2] = m[2] * c - m[1] * s
    return out
}

public func mat4RotateY(_ m: Mat4, _ rad: Float) -> Mat4 {
    let s = sin(rad), c = cos(rad)
    var out = m
    out[0] = m[0] * c - m[2] * s
    out[2] = m[0] * s + m[2] * c
    return out
}

public func mat4RotateZ(_ m: Mat4, _ rad: Float) -> Mat4 {
    let s = sin(rad), c = cos(rad)
    var out = m
    out[0] = m[0] * c + m[1] * s
    out[1] = m[1] * c - m[0] * s
    return out
}

// ---- AABB (Double — collision space) -------------------------------------------
public struct AABB {
    public var x0: Double, y0: Double, z0: Double
    public var x1: Double, y1: Double, z1: Double

    @inline(__always)
    public init(_ x0: Double, _ y0: Double, _ z0: Double, _ x1: Double, _ y1: Double, _ z1: Double) {
        self.x0 = x0; self.y0 = y0; self.z0 = z0
        self.x1 = x1; self.y1 = y1; self.z1 = z1
    }

    @inline(__always)
    public func offset(_ x: Double, _ y: Double, _ z: Double) -> AABB {
        AABB(x0 + x, y0 + y, z0 + z, x1 + x, y1 + y, z1 + z)
    }

    @inline(__always)
    public func expand(_ x: Double, _ y: Double, _ z: Double) -> AABB {
        AABB(x0 - x, y0 - y, z0 - z, x1 + x, y1 + y, z1 + z)
    }

    @inline(__always)
    public func intersects(_ b: AABB) -> Bool {
        x0 < b.x1 && x1 > b.x0 && y0 < b.y1 && y1 > b.y0 && z0 < b.z1 && z1 > b.z0
    }

    @inline(__always)
    public func contains(_ x: Double, _ y: Double, _ z: Double) -> Bool {
        x >= x0 && x < x1 && y >= y0 && y < y1 && z >= z0 && z < z1
    }
}

/// how far box `a` may move along X by `d` before hitting `b`
@inline(__always)
public func sweepX(_ a: AABB, _ b: AABB, _ dIn: Double) -> Double {
    var d = dIn
    if a.y1 <= b.y0 || a.y0 >= b.y1 || a.z1 <= b.z0 || a.z0 >= b.z1 { return d }
    if d > 0 && a.x1 <= b.x0 { let m = b.x0 - a.x1; if m < d { d = m } }
    else if d < 0 && a.x0 >= b.x1 { let m = b.x1 - a.x0; if m > d { d = m } }
    return d
}

@inline(__always)
public func sweepY(_ a: AABB, _ b: AABB, _ dIn: Double) -> Double {
    var d = dIn
    if a.x1 <= b.x0 || a.x0 >= b.x1 || a.z1 <= b.z0 || a.z0 >= b.z1 { return d }
    if d > 0 && a.y1 <= b.y0 { let m = b.y0 - a.y1; if m < d { d = m } }
    else if d < 0 && a.y0 >= b.y1 { let m = b.y1 - a.y0; if m > d { d = m } }
    return d
}

@inline(__always)
public func sweepZ(_ a: AABB, _ b: AABB, _ dIn: Double) -> Double {
    var d = dIn
    if a.x1 <= b.x0 || a.x0 >= b.x1 || a.y1 <= b.y0 || a.y0 >= b.y1 { return d }
    if d > 0 && a.z1 <= b.z0 { let m = b.z0 - a.z1; if m < d { d = m } }
    else if d < 0 && a.z0 >= b.z1 { let m = b.z1 - a.z0; if m > d { d = m } }
    return d
}

/// ray vs AABB; returns t or -1
public func rayAABB(_ ox: Double, _ oy: Double, _ oz: Double, _ dx: Double, _ dy: Double, _ dz: Double, _ b: AABB) -> Double {
    var tmin = -Double.infinity, tmax = Double.infinity
    if abs(dx) < 1e-12 { if ox < b.x0 || ox > b.x1 { return -1 } }
    else {
        var t1 = (b.x0 - ox) / dx, t2 = (b.x1 - ox) / dx
        if t1 > t2 { swap(&t1, &t2) }
        tmin = max(tmin, t1); tmax = min(tmax, t2)
    }
    if abs(dy) < 1e-12 { if oy < b.y0 || oy > b.y1 { return -1 } }
    else {
        var t1 = (b.y0 - oy) / dy, t2 = (b.y1 - oy) / dy
        if t1 > t2 { swap(&t1, &t2) }
        tmin = max(tmin, t1); tmax = min(tmax, t2)
    }
    if abs(dz) < 1e-12 { if oz < b.z0 || oz > b.z1 { return -1 } }
    else {
        var t1 = (b.z0 - oz) / dz, t2 = (b.z1 - oz) / dz
        if t1 > t2 { swap(&t1, &t2) }
        tmin = max(tmin, t1); tmax = min(tmax, t2)
    }
    if tmax < tmin || tmax < 0 { return -1 }
    return tmin >= 0 ? tmin : tmax
}

// ---- frustum (Float, Metal clip space) ------------------------------------------
public struct Frustum {
    /// 6 planes × (a,b,c,d): left, right, bottom, top, near, far
    public var planes = [Float](repeating: 0, count: 24)

    public init() {}

    public mutating func setFromMatrix(_ m: Mat4) {
        // rows of the column-major matrix
        let r0 = SIMD4<Float>(m[0][0], m[1][0], m[2][0], m[3][0])
        let r1 = SIMD4<Float>(m[0][1], m[1][1], m[2][1], m[3][1])
        let r2 = SIMD4<Float>(m[0][2], m[1][2], m[2][2], m[3][2])
        let r3 = SIMD4<Float>(m[0][3], m[1][3], m[2][3], m[3][3])
        // Metal clip: -w ≤ x,y ≤ w and 0 ≤ z ≤ w → near plane is r2 alone
        let ps: [SIMD4<Float>] = [r3 + r0, r3 - r0, r3 + r1, r3 - r1, r2, r3 - r2]
        for (i, pl) in ps.enumerated() {
            let len = sqrt(pl.x * pl.x + pl.y * pl.y + pl.z * pl.z)
            let n = len > 0 ? pl / len : pl
            planes[i * 4] = n.x
            planes[i * 4 + 1] = n.y
            planes[i * 4 + 2] = n.z
            planes[i * 4 + 3] = n.w
        }
    }

    @inline(__always)
    public func intersectsBox(_ x0: Float, _ y0: Float, _ z0: Float, _ x1: Float, _ y1: Float, _ z1: Float) -> Bool {
        for i in 0..<6 {
            let o = i * 4
            let px = planes[o] > 0 ? x1 : x0
            let py = planes[o + 1] > 0 ? y1 : y0
            let pz = planes[o + 2] > 0 ? z1 : z0
            if planes[o] * px + planes[o + 1] * py + planes[o + 2] * pz + planes[o + 3] < 0 { return false }
        }
        return true
    }
}
