import PebbleRenderABI

public struct UIBatch: Sendable {
    public var vertices: [UIVertex]
    public init(vertices: [UIVertex]) { self.vertices = vertices }

    public var meshData: RenderMeshData {
        RenderMeshData(vertexLayout: .ui,
                       vertexBytes: vertices.withUnsafeBytes { Array($0) })
    }
}

public final class UICanvasCPU {
    public var width: Float
    public var height: Float
    public var color = SIMD4<Float>(1, 1, 1, 1)
    private var vertices: [UIVertex] = []

    public init(width: Float, height: Float) {
        self.width = width
        self.height = height
    }

    public func begin(width: Float, height: Float) {
        self.width = width
        self.height = height
        vertices.removeAll(keepingCapacity: true)
        color = SIMD4<Float>(1, 1, 1, 1)
    }

    public func fillRect(x: Float, y: Float, width: Float, height: Float,
                         color: SIMD4<Float>) {
        quad(x: x, y: y, width: width, height: height, color: color)
    }

    public func gradientRect(x: Float, y: Float, width: Float, height: Float,
                             top: SIMD4<Float>, bottom: SIMD4<Float>) {
        let p0 = UIVertex(x: x, y: y, u: 0.5, v: 0.5, r: top.x, g: top.y, b: top.z, a: top.w)
        let p1 = UIVertex(x: x + width, y: y, u: 0.5, v: 0.5, r: top.x, g: top.y, b: top.z, a: top.w)
        let p2 = UIVertex(x: x + width, y: y + height, u: 0.5, v: 0.5, r: bottom.x, g: bottom.y, b: bottom.z, a: bottom.w)
        let p3 = UIVertex(x: x, y: y + height, u: 0.5, v: 0.5, r: bottom.x, g: bottom.y, b: bottom.z, a: bottom.w)
        vertices.append(contentsOf: [p0, p1, p2, p0, p2, p3])
    }

    @discardableResult
    public func text(_ value: String, x: Float, y: Float, scale: Float = 1,
                     color: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
                     shadow: Bool = true) -> Float {
        if shadow {
            _ = emitText(value, x: x + scale, y: y + scale, scale: scale,
                         color: SIMD4<Float>(0, 0, 0, color.w * 0.65))
        }
        return emitText(value, x: x, y: y, scale: scale, color: color)
    }

    public func textCentered(_ value: String, centerX: Float, y: Float,
                             scale: Float = 1, color: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)) {
        let width = Float(value.count * 6 - (value.isEmpty ? 0 : 1)) * scale
        _ = text(value, x: centerX - width / 2, y: y, scale: scale, color: color)
    }

    public func finish() -> UIBatch { UIBatch(vertices: vertices) }

    private func emitText(_ value: String, x: Float, y: Float, scale: Float,
                          color: SIMD4<Float>) -> Float {
        var cursor = x
        for character in value.uppercased() {
            if character == " " { cursor += 4 * scale; continue }
            let rows = Font5x7.rows(for: character)
            for row in 0..<7 {
                let bits = rows[row]
                for column in 0..<5 where bits & (1 << (4 - column)) != 0 {
                    quad(x: cursor + Float(column) * scale, y: y + Float(row) * scale,
                         width: scale, height: scale, color: color)
                }
            }
            cursor += 6 * scale
        }
        return cursor - x
    }

    private func quad(x: Float, y: Float, width: Float, height: Float,
                      color: SIMD4<Float>) {
        let a = UIVertex(x: x, y: y, u: 0.5, v: 0.5, r: color.x, g: color.y, b: color.z, a: color.w)
        let b = UIVertex(x: x + width, y: y, u: 0.5, v: 0.5, r: color.x, g: color.y, b: color.z, a: color.w)
        let c = UIVertex(x: x + width, y: y + height, u: 0.5, v: 0.5, r: color.x, g: color.y, b: color.z, a: color.w)
        let d = UIVertex(x: x, y: y + height, u: 0.5, v: 0.5, r: color.x, g: color.y, b: color.z, a: color.w)
        vertices.append(contentsOf: [a, b, c, a, c, d])
    }
}

private enum Font5x7 {
    private static let glyphs: [Character: [UInt8]] = [
        "A":[14,17,17,31,17,17,17], "B":[30,17,17,30,17,17,30], "C":[14,17,16,16,16,17,14],
        "D":[30,17,17,17,17,17,30], "E":[31,16,16,30,16,16,31], "F":[31,16,16,30,16,16,16],
        "G":[14,17,16,23,17,17,15], "H":[17,17,17,31,17,17,17], "I":[14,4,4,4,4,4,14],
        "J":[7,2,2,2,2,18,12], "K":[17,18,20,24,20,18,17], "L":[16,16,16,16,16,16,31],
        "M":[17,27,21,21,17,17,17], "N":[17,25,21,19,17,17,17], "O":[14,17,17,17,17,17,14],
        "P":[30,17,17,30,16,16,16], "Q":[14,17,17,17,21,18,13], "R":[30,17,17,30,20,18,17],
        "S":[15,16,16,14,1,1,30], "T":[31,4,4,4,4,4,4], "U":[17,17,17,17,17,17,14],
        "V":[17,17,17,17,17,10,4], "W":[17,17,17,21,21,21,10], "X":[17,17,10,4,10,17,17],
        "Y":[17,17,10,4,4,4,4], "Z":[31,1,2,4,8,16,31],
        "0":[14,17,19,21,25,17,14], "1":[4,12,4,4,4,4,14], "2":[14,17,1,2,4,8,31],
        "3":[30,1,1,14,1,1,30], "4":[2,6,10,18,31,2,2], "5":[31,16,16,30,1,1,30],
        "6":[14,16,16,30,17,17,14], "7":[31,1,2,4,8,8,8], "8":[14,17,17,14,17,17,14],
        "9":[14,17,17,15,1,1,14], "-":[0,0,0,31,0,0,0], ".":[0,0,0,0,0,12,12],
        ":":[0,12,12,0,12,12,0], "/":[1,2,2,4,8,8,16], "?":[14,17,1,2,4,0,4]
    ]
    static func rows(for character: Character) -> [UInt8] { glyphs[character] ?? glyphs["?"]! }
}
