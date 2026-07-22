// Pure 4×4 transform math over the `M44` value lives in the render model.
//
// Earlier code treated transform concatenation as renderer-side (it lived in `valence/presentation/swift/
// M44Math.swift`). The model-side animation tick (`RetainedTreeStore.tick`)
// rebuilds a layer's transform override from its animated components, so the
// math now belongs with the model. The presentation geometry walk keeps using
// it through `import NucleusRenderModel`. Column-major Skia `SkM44` layout
// (`m[col*4 + row]`). The Skia-bridge `invert`/
// `decompose2D` stay deferred — they cross into SkM44 and no CPU caller uses them.

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

/// Result of mapping a 2D rect: bounding box of the projected corners.
public struct MappedRect: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var w: Float
    public var h: Float

    public init(x: Float, y: Float, w: Float, h: Float) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

extension M44 {
    public static func translate(_ tx: Float, _ ty: Float, _ tz: Float) -> M44 {
        M44(m: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            tx, ty, tz, 1,
        ])
    }

    public static func scale(_ sx: Float, _ sy: Float, _ sz: Float) -> M44 {
        M44(m: [
            sx, 0, 0, 0,
            0, sy, 0, 0,
            0, 0, sz, 0,
            0, 0, 0, 1,
        ])
    }

    /// Rotation about the X axis by `theta` radians. Mirrors `M44.rotateX`.
    public static func rotateX(_ theta: Float) -> M44 {
        let c = cosf(theta)
        let s = sinf(theta)
        return M44(m: [
            1, 0, 0, 0,
            0, c, s, 0,
            0, -s, c, 0,
            0, 0, 0, 1,
        ])
    }

    /// Rotation about the Y axis by `theta` radians. Mirrors `M44.rotateY`.
    public static func rotateY(_ theta: Float) -> M44 {
        let c = cosf(theta)
        let s = sinf(theta)
        return M44(m: [
            c, 0, -s, 0,
            0, 1, 0, 0,
            s, 0, c, 0,
            0, 0, 0, 1,
        ])
    }

    /// Rotation about the Z axis by `theta` radians. Mirrors `M44.rotateZ`.
    public static func rotateZ(_ theta: Float) -> M44 {
        let c = cosf(theta)
        let s = sinf(theta)
        return M44(m: [
            c, s, 0, 0,
            -s, c, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ])
    }

    /// Concatenate: self × other (apply `other` first, then `self`). General
    /// column-combination path.
    public func concat(_ b: M44) -> M44 {
        let a = m
        func col(_ i: Int) -> (Float, Float, Float, Float) {
            (a[i * 4], a[i * 4 + 1], a[i * 4 + 2], a[i * 4 + 3])
        }
        let a0 = col(0), a1 = col(1), a2 = col(2), a3 = col(3)
        var out = [Float](repeating: 0, count: 16)
        for c in 0..<4 {
            let b0 = b.m[c * 4], b1 = b.m[c * 4 + 1], b2 = b.m[c * 4 + 2], b3 = b.m[c * 4 + 3]
            out[c * 4 + 0] = a0.0 * b0 + a1.0 * b1 + a2.0 * b2 + a3.0 * b3
            out[c * 4 + 1] = a0.1 * b0 + a1.1 * b1 + a2.1 * b2 + a3.1 * b3
            out[c * 4 + 2] = a0.2 * b0 + a1.2 * b1 + a2.2 * b2 + a3.2 * b3
            out[c * 4 + 3] = a0.3 * b0 + a1.3 * b1 + a2.3 * b2 + a3.3 * b3
        }
        return M44(m: out)
    }

    /// Map a 2D point (z=0, w=1) through the matrix; returns projected (x, y).
    public func mapPoint(_ x: Float, _ y: Float) -> (x: Float, y: Float) {
        let c0x = m[0], c0y = m[1], c0w = m[3]
        let c1x = m[4], c1y = m[5], c1w = m[7]
        let c3x = m[12], c3y = m[13], c3w = m[15]
        let px = c0x * x + c1x * y + c3x
        let py = c0y * x + c1y * y + c3y
        let pw = c0w * x + c1w * y + c3w
        if pw == 0 { return (0, 0) }
        if pw != 1 {
            let invW = 1.0 / pw
            return (px * invW, py * invW)
        }
        return (px, py)
    }

    /// Map a 2D rect; return the bounding box of the projected corners.
    public func mapRect(_ x: Float, _ y: Float, _ w: Float, _ h: Float) -> MappedRect {
        let tl = mapPoint(x, y)
        let tr = mapPoint(x + w, y)
        let bl = mapPoint(x, y + h)
        let br = mapPoint(x + w, y + h)
        let minX = min(min(tl.x, tr.x), min(bl.x, br.x))
        let minY = min(min(tl.y, tr.y), min(bl.y, br.y))
        let maxX = max(max(tl.x, tr.x), max(bl.x, br.x))
        let maxY = max(max(tl.y, tr.y), max(bl.y, br.y))
        return MappedRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }

    /// True when the matrix is a pure 2D affine (Z/W rows/cols identity except
    /// X/Y translation, no perspective). Mirrors `is2DAffine`.
    public var is2DAffine: Bool {
        let eps: Float = 1e-6
        if abs(m[8]) > eps { return false }
        if abs(m[9]) > eps { return false }
        if abs(m[10] - 1.0) > eps { return false }
        if abs(m[11]) > eps { return false }
        if abs(m[14]) > eps { return false }
        if abs(m[15] - 1.0) > eps { return false }
        if abs(m[2]) > eps { return false }
        if abs(m[3]) > eps { return false }
        if abs(m[6]) > eps { return false }
        if abs(m[7]) > eps { return false }
        return true
    }

    /// Lift a row-major 3×3 (`[9]` SkMatrix layout) into a 4×4. Mirrors
    /// `from3x3`: `[sx kx tx; ky sy ty; p0 p1 p2]`.
    public static func from3x3(_ m3: [Float]) -> M44 {
        M44(m: [
            m3[0], m3[3], 0, m3[6], // col 0
            m3[1], m3[4], 0, m3[7], // col 1
            0, 0, 1, 0, // col 2 (Z basis)
            m3[2], m3[5], 0, m3[8], // col 3 (translation + perspective W)
        ])
    }

    public func approxEqual(_ other: M44, eps: Float) -> Bool {
        for (a, b) in zip(m, other.m) where abs(a - b) > eps { return false }
        return true
    }
}
