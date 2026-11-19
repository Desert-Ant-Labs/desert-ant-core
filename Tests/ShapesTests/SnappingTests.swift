import Foundation
import Testing
@testable import Shapes

/// Snapping to regular shapes and the three rotation modes, on exact geometry.
struct SnappingTests {
    static func rotated(_ pts: [Point], by degrees: Double, about c: Point = Point(x: 0, y: 0)) -> [Point] {
        let a = degrees * Double.pi / 180
        return pts.map { p in
            let x = p.x - c.x, y = p.y - c.y
            return Point(x: c.x + x * cos(a) - y * sin(a), y: c.y + x * sin(a) + y * cos(a))
        }
    }

    static func angle(_ a: Point, _ b: Point) -> Double { atan2(b.y - a.y, b.x - a.x) * 180 / Double.pi }

    static let box = [Point(x: -60, y: -30), Point(x: 60, y: -30), Point(x: 60, y: 30), Point(x: -60, y: 30)]

    @Test func lineSnapsOntoAnAxisWithinFiveDegrees() {
        let near = Snapping.apply(.line(from: Point(x: 0, y: 0), to: Point(x: 100, y: 4)), rotation: .snapped)
        guard case let .line(a, b) = near else { Issue.record("expected a line"); return }
        #expect(abs(a.y - b.y) < 1e-9)
        let far = Snapping.apply(.line(from: Point(x: 0, y: 0), to: Point(x: 100, y: 30)), rotation: .snapped)
        #expect(far == .line(from: Point(x: 0, y: 0), to: Point(x: 100, y: 30)))
    }

    @Test func rectangleRotationPerMode() {
        let tilted = Shape.rectangle(corners: Self.rotated(Self.box, by: 7))
        guard case let .rectangle(snapped) = Snapping.apply(tilted, rotation: .snapped),
              case let .rectangle(upright) = Snapping.apply(tilted, rotation: .upright),
              case let .rectangle(free) = Snapping.apply(tilted, rotation: .free) else {
            Issue.record("expected rectangles"); return
        }
        #expect(abs(Self.angle(snapped[0], snapped[1])) < 1e-9)   // 7° rounds to the 0° step
        #expect(abs(Self.angle(upright[0], upright[1])) < 1e-9)
        #expect(abs(Self.angle(free[0], free[1]) - 7) < 1e-9)
        let steep = Shape.rectangle(corners: Self.rotated(Self.box, by: 31))
        guard case let .rectangle(s) = Snapping.apply(steep, rotation: .snapped),
              case let .rectangle(u) = Snapping.apply(steep, rotation: .upright) else { return }
        #expect(abs(Self.angle(s[0], s[1]) - 30) < 1e-9)
        #expect(abs(Self.angle(u[0], u[1])) < 1e-9)
    }

    @Test func nearSquareBecomesSquareUnlessFree() {
        let near = Shape.rectangle(corners: [Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 95), Point(x: 0, y: 95)])
        guard case let .rectangle(c) = Snapping.apply(near, rotation: .snapped) else { return }
        #expect(abs(hypot(c[1].x - c[0].x, c[1].y - c[0].y) - hypot(c[3].x - c[0].x, c[3].y - c[0].y)) < 1e-9)
        #expect(Snapping.apply(near, rotation: .free) == near)
    }

    @Test func ellipseCircleAndAxes() {
        let round = Snapping.apply(.ellipse(center: Point(x: 0, y: 0), semiMajor: 100, semiMinor: 90, rotation: 0.4), rotation: .snapped)
        #expect(round == .ellipse(center: Point(x: 0, y: 0), semiMajor: 95, semiMinor: 95, rotation: 0))
        guard case let .ellipse(_, _, _, r) = Snapping.apply(
            .ellipse(center: Point(x: 0, y: 0), semiMajor: 100, semiMinor: 40, rotation: 1.2), rotation: .upright) else { return }
        #expect(abs(r - Double.pi / 2) < 1e-9)
    }

    @Test func uprightTriangleSitsOnAnEdge() {
        let tri = [Point(x: 0, y: 0), Point(x: 120, y: 0), Point(x: 30, y: -70)]
        guard case let .triangle(v) = Snapping.apply(.triangle(vertices: Self.rotated(tri, by: 23)), rotation: .upright) else { return }
        let flat = (0..<3).contains { abs(v[$0].y - v[($0 + 1) % 3].y) < 1e-6 }
        #expect(flat)
    }

    @Test func regularPolygonsAndStars() {
        let hex = (0..<6).map { i -> Point in
            let a = Double(i) * Double.pi / 3 + 0.2 + (i == 2 ? 0.03 : 0)
            return Point(x: 50 * cos(a), y: 50 * sin(a))
        }
        guard case let .hexagon(v) = Snapping.apply(.hexagon(vertices: hex), rotation: .upright) else { return }
        // flat-topped or pointy-topped: a vertex level with the center or straight above it
        let cx = v.map(\.x).reduce(0, +) / 6, cy = v.map(\.y).reduce(0, +) / 6
        #expect(v.contains { abs($0.y - cy) < 1e-6 || abs($0.x - cx) < 1e-6 })
        let sides = (0..<6).map { hypot(v[($0 + 1) % 6].x - v[$0].x, v[($0 + 1) % 6].y - v[$0].y) }
        #expect(sides.max()! - sides.min()! < 1e-6)
        let star = Shape.star(center: Point(x: 0, y: 0), outerRadius: 50, innerRadius: 20, rotation: 0.3, pointCount: 5)
        guard case let .star(_, _, _, r, _) = Snapping.apply(star, rotation: .upright) else { return }
        #expect(r == 0)
    }

    @Test func diamondDiagonalsBecomePerpendicularAndUpright() {
        let d = [Point(x: 0, y: -50), Point(x: 42, y: 3), Point(x: 2, y: 50), Point(x: -40, y: -2)]
        guard case let .diamond(v) = Snapping.apply(.diamond(vertices: Self.rotated(d, by: 8)), rotation: .upright) else { return }
        #expect(abs(v[0].x - v[2].x) < 1e-6)   // vertical diagonal
        #expect(abs(v[1].y - v[3].y) < 1e-6)   // horizontal diagonal
    }

    @Test func outlinesAndArrowheads() {
        let arrow = Shape.arrow(from: Point(x: 0, y: 0), control1: Point(x: 33, y: 0), control2: Point(x: 66, y: 0),
                                to: Point(x: 100, y: 0), startHead: false, endHead: true)
        let heads = arrow.arrowheads(length: 10)
        #expect(heads.count == 1)
        #expect(heads[0][1] == Point(x: 100, y: 0))
        #expect(heads[0][0].x < 100 && heads[0][2].x < 100)
        #expect(arrow.outline(samples: 16).count == 16)
        #expect(!arrow.isClosed && Shape.heart(center: Point(x: 0, y: 0), width: 10, height: 9).isClosed)
        #expect(Shape.star(center: Point(x: 0, y: 0), outerRadius: 1, innerRadius: 0.4, rotation: 0, pointCount: 5)
            .outline()[0].y < -0.99)  // a tip straight up
    }

    @Test func plusStandsSquareWithEqualArms() {
        // a level stroke tilted 4°, 100 long, and an upright one 80 long, crossing off their middles
        let plus = Shape.plus(firstFrom: Point(x: -40, y: 0), firstTo: Point(x: 60, y: 7),
                              secondFrom: Point(x: 0, y: -30), secondTo: Point(x: 3, y: 50))
        for rotation in [Rotation.snapped, .upright] {
            guard case let .plus(a, b, c, e) = Snapping.apply(plus, rotation: rotation) else {
                Issue.record("expected a plus"); return
            }
            #expect(abs(Self.angle(a, b)) < 1e-9)                       // left to right, level
            #expect(abs(Self.angle(c, e) - 90) < 1e-9)                  // top to bottom (y down), upright
            let l1 = hypot(b.x - a.x, b.y - a.y), l2 = hypot(e.x - c.x, e.y - c.y)
            let mean = (hypot(100.0, 7.0) + hypot(3.0, 80.0)) / 2
            #expect(abs(l1 - l2) < 1e-9 && abs(l1 - mean) < 1e-6)       // equal arms, their mean
            #expect(abs((a.x + b.x) / 2 - (c.x + e.x) / 2) < 1e-9)      // crossing at both middles
            #expect(abs((a.y + b.y) / 2 - (c.y + e.y) / 2) < 1e-9)
        }
        #expect(Snapping.apply(plus, rotation: .free) == plus)
    }

    @Test func crossTurnsToAnEvenX() {
        // two strokes from their upper ends, at 40° and 133°, one 30% shorter
        let r1 = 40 * Double.pi / 180, r2 = 133 * Double.pi / 180
        let cross = Shape.cross(firstFrom: Point(x: -50 * cos(r1), y: -50 * sin(r1)), firstTo: Point(x: 50 * cos(r1), y: 50 * sin(r1)),
                                secondFrom: Point(x: -35 * cos(r2), y: -35 * sin(r2)), secondTo: Point(x: 35 * cos(r2), y: 35 * sin(r2)))
        guard case let .cross(a, b, c, e) = Snapping.apply(cross, rotation: .upright) else {
            Issue.record("expected a cross"); return
        }
        #expect(abs(Self.angle(a, b) - 45) < 1e-9)
        #expect(abs(Self.angle(c, e) - 135) < 1e-9)
        #expect(abs(hypot(b.x - a.x, b.y - a.y) - hypot(e.x - c.x, e.y - c.y)) < 1e-9)
        // a long and a very short stroke keep their own lengths
        let lopsided = Shape.cross(firstFrom: Point(x: -50, y: -50), firstTo: Point(x: 50, y: 50),
                                   secondFrom: Point(x: 10, y: -10), secondTo: Point(x: -10, y: 10))
        guard case let .cross(p, q, s, t) = Snapping.apply(lopsided, rotation: .snapped) else { return }
        #expect(hypot(q.x - p.x, q.y - p.y) > 3 * hypot(t.x - s.x, t.y - s.y))
    }

    @Test func bracketSpineStraightEndsSquare() {
        // a "[": top end, two corners, bottom end; the spine leans 3°, the ends are uneven and slanted
        let bracket = Shape.bracket(points: [Point(x: 22, y: -48), Point(x: 2, y: -50), Point(x: -3, y: 50), Point(x: 16, y: 54)])
        guard case let .bracket(p) = Snapping.apply(bracket, rotation: .snapped) else {
            Issue.record("expected a bracket"); return
        }
        #expect(abs(p[1].x - p[2].x) < 1e-9)                            // the spine upright
        #expect(abs(p[0].y - p[1].y) < 1e-9 && abs(p[3].y - p[2].y) < 1e-9)   // both ends level
        #expect(p[0].x > p[1].x && p[3].x > p[2].x)                     // on the side drawn
        #expect(abs((p[0].x - p[1].x) - (p[3].x - p[2].x)) < 1e-9)      // as long as each other
    }

    @Test func checkCornerSquareArmsKept() {
        // y down: the short arm comes down to the corner, the long one rises right at 50°, the corner 70°
        let corner = Point(x: 0, y: 0)
        let rl = -50 * Double.pi / 180, rs = -120 * Double.pi / 180
        let check = Shape.check(start: Point(x: 20 * cos(rs), y: 20 * sin(rs)), corner: corner,
                                end: Point(x: 60 * cos(rl), y: 60 * sin(rl)))
        for (rotation, long) in [(Rotation.snapped, -45.0), (.upright, -45.0)] {
            guard case let .check(s, c, e) = Snapping.apply(check, rotation: rotation) else {
                Issue.record("expected a check"); return
            }
            #expect(c == corner)
            #expect(abs(Self.angle(c, e) - long) < 1e-9)
            #expect(abs(hypot(e.x, e.y) - 60) < 1e-9 && abs(hypot(s.x, s.y) - 20) < 1e-9)
            #expect(abs(s.x * e.x + s.y * e.y) < 1e-9)                  // square at the corner
            #expect(s.x < 0)                                            // the short arm on the left, as drawn
        }
        #expect(Snapping.apply(check, rotation: .free) == check)
    }
}
