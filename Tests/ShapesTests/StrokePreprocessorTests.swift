import Foundation
import XCTest
@testable import Shapes

final class StrokePreprocessorTests: XCTestCase {
    let pre = StrokePreprocessor()

    // Cross-language parity: reference values produced by the Python
    // `preprocess.py` for this exact input with the frozen config.
    func testMatchesPythonReference() throws {
        let stroke = [
            Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 10, y: 8),
            Point(x: 2, y: 8), Point(x: 2, y: 3),
        ]
        let f = try pre.process(points: stroke)

        XCTAssertEqual(f.count, 156)

        let sumDist = f.reduce(0.0) { $0 + Double($1.distance) }
        let sumCos = f.reduce(0.0) { $0 + Double($1.cosTheta) }
        let sumSin = f.reduce(0.0) { $0 + Double($1.sinTheta) }
        XCTAssertEqual(sumDist, 45.059365, accuracy: 1e-3)
        XCTAssertEqual(sumCos, 10.0, accuracy: 1e-3)
        XCTAssertEqual(sumSin, 15.0, accuracy: 1e-3)

        assertPoint(f[0], -9.277467, 0.0, 0.0)
        assertPoint(f[1], 0.35056, 1.0, 0.0)
        assertPoint(f[2], 0.35056, 1.0, 0.0)
        assertPoint(f[154], 0.35056, 0.0, -1.0)
        assertPoint(f[155], 0.35056, 0.0, -1.0)
    }

    func testFirstPointIsZeroDirection() throws {
        let f = try pre.process(points: [Point(x: 0, y: 0), Point(x: 5, y: 0)])
        XCTAssertEqual(f[0].cosTheta, 0)
        XCTAssertEqual(f[0].sinTheta, 0)
    }

    func testStraightLineHasConstantDirection() throws {
        let pts = (0...20).map { Point(x: Double($0), y: 0) }
        let f = try pre.process(points: pts)
        for p in f.dropFirst() {
            XCTAssertEqual(p.cosTheta, 1.0, accuracy: 1e-5)
            XCTAssertEqual(p.sinTheta, 0.0, accuracy: 1e-5)
        }
    }

    func testCircleDirectionRotatesFullTurn() throws {
        var pts: [Point] = []
        let n = 200
        for i in 0...n {
            let t = 2.0 * Double.pi * Double(i) / Double(n)
            pts.append(Point(x: cos(t), y: sin(t)))
        }
        let f = try pre.process(points: pts)
        // Direction angle should sweep close to a full 2π around the circle.
        var total = 0.0
        var prev = atan2(Double(f[1].sinTheta), Double(f[1].cosTheta))
        for p in f.dropFirst(2) {
            let a = atan2(Double(p.sinTheta), Double(p.cosTheta))
            var d = a - prev
            if d > Double.pi { d -= 2 * Double.pi }
            if d < -Double.pi { d += 2 * Double.pi }
            total += d
            prev = a
        }
        XCTAssertEqual(abs(total), 2 * Double.pi, accuracy: 0.2)
    }

    func testCurvatureChannelEnabled() throws {
        let cfg = PreprocessConfig(addCurvature: true)
        let p = StrokePreprocessor(config: cfg)
        let pts = (0...20).map { Point(x: Double($0), y: 0) }
        let f = try p.process(points: pts)
        // A straight line has ~zero turning angle everywhere.
        for pt in f { XCTAssertEqual(pt.curvature, 0, accuracy: 1e-5) }
    }

    func testRejectsTooFewPoints() {
        XCTAssertThrowsError(try pre.process(points: [Point(x: 1, y: 1)]))
    }

    func testRejectsDuplicatePointsAsDegenerate() {
        let dup = [Point(x: 3, y: 3), Point(x: 3, y: 3), Point(x: 3, y: 3)]
        XCTAssertThrowsError(try pre.process(points: dup))
    }

    private func assertPoint(_ p: StrokePoint, _ d: Float, _ c: Float, _ s: Float,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.distance, d, accuracy: 1e-3, file: file, line: line)
        XCTAssertEqual(p.cosTheta, c, accuracy: 1e-3, file: file, line: line)
        XCTAssertEqual(p.sinTheta, s, accuracy: 1e-3, file: file, line: line)
    }
}
