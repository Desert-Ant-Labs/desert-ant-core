import Foundation
import Testing
@testable import Shapes

/// Exercises the geometric fitters directly (no model): min-area rectangle,
/// moment-fit ellipse, and pose+template star. Uses the portable ``Point``.
struct FitterTests {
    private func angleModPi(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: .pi)
        if x < 0 { x += .pi }
        return x
    }

    @Test func momentEllipseRecoversAxesAndRotation() throws {
        let a = 100.0, b = 40.0, rot = 30.0 * .pi / 180
        let c = Point(x: 250, y: 180)
        let pts = (0..<200).map { i -> Point in
            let t = 2 * Double.pi * Double(i) / 200
            let x = a * cos(t), y = b * sin(t)
            return Point(x: c.x + x * cos(rot) - y * sin(rot),
                         y: c.y + x * sin(rot) + y * cos(rot))
        }
        let (shape, residual) = Fitter.fit(.ellipse, points: pts, snap: .disabled)
        guard case let .ellipse(center, major, minor, rotation) = shape else {
            Issue.record("expected ellipse, got \(shape)")
            return
        }
        #expect(abs(center.x - 250) <= 2)
        #expect(abs(center.y - 180) <= 2)
        #expect(abs(major - a) <= 3)
        #expect(abs(minor - b) <= 3)
        #expect(abs(angleModPi(rotation) - angleModPi(rot)) <= 0.03)
        #expect(residual < 0.02)
    }

    @Test func minAreaRectangleRecoversCornersAndOrientation() throws {
        let w = 120.0, h = 60.0, rot = 20.0 * .pi / 180
        let cx = 200.0, cy = 200.0
        let local = [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)]
        let world = local.map { v in
            (cx + v.0 * cos(rot) - v.1 * sin(rot), cy + v.0 * sin(rot) + v.1 * cos(rot))
        }
        var pts: [Point] = []
        for k in 0..<4 {
            let p = world[k], q = world[(k + 1) % 4]
            for s in 0..<40 {
                let t = Double(s) / 40
                pts.append(Point(x: p.0 + (q.0 - p.0) * t, y: p.1 + (q.1 - p.1) * t))
            }
        }
        let (shape, residual) = Fitter.fit(.rectangle, points: pts, snap: .disabled)
        guard case let .rectangle(corners) = shape else {
            Issue.record("expected rectangle, got \(shape)")
            return
        }
        #expect(corners.count == 4)
        let side0 = hypot(corners[1].x - corners[0].x, corners[1].y - corners[0].y)
        let side1 = hypot(corners[3].x - corners[0].x, corners[3].y - corners[0].y)
        let (long, short) = side0 > side1 ? (side0, side1) : (side1, side0)
        #expect(abs(long - w) <= 3)
        #expect(abs(short - h) <= 3)
        #expect(residual < 0.02)
    }

    @Test func starPoseRecoversRotationAndRadius() throws {
        let outer = 100.0, inner = 40.0, rot = 12.0 * .pi / 180
        let cx = 160.0, cy = 160.0
        let verts = (0..<10).map { i -> (Double, Double) in
            let aa = rot - .pi / 2 + Double(i) * .pi / 5
            let r = i % 2 == 0 ? outer : inner
            return (cx + r * cos(aa), cy + r * sin(aa))
        }
        var pts: [Point] = []
        for k in 0..<10 {
            let p = verts[k], q = verts[(k + 1) % 10]
            for s in 0..<20 {
                let t = Double(s) / 20
                pts.append(Point(x: p.0 + (q.0 - p.0) * t, y: p.1 + (q.1 - p.1) * t))
            }
        }
        let (shape, residual) = Fitter.fit(.star, points: pts, snap: .disabled)
        guard case let .star(center, outerR, _, rotation, count) = shape else {
            Issue.record("expected star, got \(shape)")
            return
        }
        #expect(count == 5)
        #expect(abs(center.x - 160) <= 3)
        #expect(abs(outerR - outer) <= 12)
        // Star rotation is periodic in 72°.
        let drot = abs((rotation - rot).truncatingRemainder(dividingBy: 2 * .pi / 5))
        #expect(min(drot, 2 * .pi / 5 - drot) < 0.06, "rotation off by \(drot)")
        #expect(residual < 0.05)
    }
}
