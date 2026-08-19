import RealModule

/// Internal 2D vector math. Replaces `simd` (Apple-only) with a small portable
/// struct so the geometric fitters and snapping run identically on every
/// platform (Apple, Linux, Android, wasm). All transcendental math goes through
/// `swift-numerics` (`Double.cos`, `Double.atan2`, ...); the stdlib has none and
/// importing the platform libm per target is messier.
struct V2: Equatable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    static func + (a: V2, b: V2) -> V2 { V2(a.x + b.x, a.y + b.y) }
    static func - (a: V2, b: V2) -> V2 { V2(a.x - b.x, a.y - b.y) }
    static func * (s: Double, v: V2) -> V2 { V2(s * v.x, s * v.y) }
    static func * (v: V2, s: Double) -> V2 { V2(v.x * s, v.y * s) }
    static func / (v: V2, s: Double) -> V2 { V2(v.x / s, v.y / s) }

    var length: Double { (x * x + y * y).squareRoot() }
}

func dot(_ a: V2, _ b: V2) -> Double { a.x * b.x + a.y * b.y }
/// The z component of the 3D cross product of two planar vectors.
func crossZ(_ a: V2, _ b: V2) -> Double { a.x * b.y - a.y * b.x }
func vmin(_ a: V2, _ b: V2) -> V2 { V2(Swift.min(a.x, b.x), Swift.min(a.y, b.y)) }
func vmax(_ a: V2, _ b: V2) -> V2 { V2(Swift.max(a.x, b.x), Swift.max(a.y, b.y)) }

/// A 2x2 rotation matrix (columns), replacing `simd_double2x2`.
struct Mat2 {
    let c0: V2
    let c1: V2

    /// Rotation by `angle` (radians).
    static func rotation(_ angle: Double) -> Mat2 {
        let c = Double.cos(angle), s = Double.sin(angle)
        return Mat2(c0: V2(c, s), c1: V2(-s, c))   // columns
    }

    static func * (m: Mat2, v: V2) -> V2 {
        V2(m.c0.x * v.x + m.c1.x * v.y, m.c0.y * v.x + m.c1.y * v.y)
    }
}
