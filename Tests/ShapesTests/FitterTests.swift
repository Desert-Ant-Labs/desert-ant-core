import Foundation
import XCTest
@testable import Shapes

/// Exercises the geometric fitters directly (no model): min-area rectangle,
/// moment-fit ellipse, and pose+template star. Uses the portable ``Point``.
final class FitterTests: XCTestCase {
    private func angleModPi(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: .pi)
        if x < 0 { x += .pi }
        return x
    }

    func testMomentEllipseRecoversAxesAndRotation() {
        let a = 100.0, b = 40.0, rot = 30.0 * .pi / 180
        let c = Point(x: 250, y: 180)
        let pts = (0..<200).map { i -> Point in
            let t = 2 * Double.pi * Double(i) / 200
            let x = a * cos(t), y = b * sin(t)
            return Point(x: c.x + x * cos(rot) - y * sin(rot),
                         y: c.y + x * sin(rot) + y * cos(rot))
        }
        let (shape, residual) = Fitter.fit(.ellipse, points: pts, snap: .disabled)
        guard case let .ellipse(center, major, minor, rotation) = shape else { return XCTFail() }
        XCTAssertEqual(center.x, 250, accuracy: 2)
        XCTAssertEqual(center.y, 180, accuracy: 2)
        XCTAssertEqual(major, a, accuracy: 3)
        XCTAssertEqual(minor, b, accuracy: 3)
        XCTAssertEqual(angleModPi(rotation), angleModPi(rot), accuracy: 0.03)
        XCTAssertLessThan(residual, 0.02)
    }

    func testMinAreaRectangleRecoversCornersAndOrientation() {
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
        guard case let .rectangle(corners) = shape else { return XCTFail() }
        XCTAssertEqual(corners.count, 4)
        let side0 = hypot(corners[1].x - corners[0].x, corners[1].y - corners[0].y)
        let side1 = hypot(corners[3].x - corners[0].x, corners[3].y - corners[0].y)
        let (long, short) = side0 > side1 ? (side0, side1) : (side1, side0)
        XCTAssertEqual(long, w, accuracy: 3)
        XCTAssertEqual(short, h, accuracy: 3)
        XCTAssertLessThan(residual, 0.02)
    }

    func testStarPoseRecoversRotationAndRadius() {
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
        guard case let .star(center, outerR, _, rotation, count) = shape else { return XCTFail() }
        XCTAssertEqual(count, 5)
        XCTAssertEqual(center.x, 160, accuracy: 3)
        XCTAssertEqual(outerR, outer, accuracy: 12)
        // Star rotation is periodic in 72°.
        let drot = abs((rotation - rot).truncatingRemainder(dividingBy: 2 * .pi / 5))
        XCTAssertTrue(min(drot, 2 * .pi / 5 - drot) < 0.06, "rotation off by \(drot)")
        XCTAssertLessThan(residual, 0.05)
    }
}
