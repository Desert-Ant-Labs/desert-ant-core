import Foundation
import Testing
@testable import Shapes

struct StrokePreprocessorTests {
    let pre = StrokePreprocessor()

    // Cross-language parity: reference values produced by the Python
    // `preprocess.py` for this exact input with the frozen config.
    @Test func matchesPythonReference() throws {
        let stroke = [
            Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 10, y: 8),
            Point(x: 2, y: 8), Point(x: 2, y: 3),
        ]
        let f = try pre.process(points: stroke)

        #expect(f.count == 156)

        let sumDist = f.reduce(0.0) { $0 + Double($1.distance) }
        let sumCos = f.reduce(0.0) { $0 + Double($1.cosTheta) }
        let sumSin = f.reduce(0.0) { $0 + Double($1.sinTheta) }
        #expect(abs(sumDist - 45.059365) <= 1e-3)
        #expect(abs(sumCos - 10.0) <= 1e-3)
        #expect(abs(sumSin - 15.0) <= 1e-3)

        expectPoint(f[0], -9.277467, 0.0, 0.0)
        expectPoint(f[1], 0.35056, 1.0, 0.0)
        expectPoint(f[2], 0.35056, 1.0, 0.0)
        expectPoint(f[154], 0.35056, 0.0, -1.0)
        expectPoint(f[155], 0.35056, 0.0, -1.0)
    }

    @Test func firstPointIsZeroDirection() throws {
        let f = try pre.process(points: [Point(x: 0, y: 0), Point(x: 5, y: 0)])
        #expect(f[0].cosTheta == 0)
        #expect(f[0].sinTheta == 0)
    }

    @Test func straightLineHasConstantDirection() throws {
        let pts = (0...20).map { Point(x: Double($0), y: 0) }
        let f = try pre.process(points: pts)
        for p in f.dropFirst() {
            #expect(abs(p.cosTheta - 1.0) <= 1e-5)
            #expect(abs(p.sinTheta - 0.0) <= 1e-5)
        }
    }

    @Test func circleDirectionRotatesFullTurn() throws {
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
        #expect(abs(abs(total) - 2 * Double.pi) <= 0.2)
    }

    @Test func curvatureChannelEnabled() throws {
        let cfg = PreprocessConfig(addCurvature: true)
        let p = StrokePreprocessor(config: cfg)
        let pts = (0...20).map { Point(x: Double($0), y: 0) }
        let f = try p.process(points: pts)
        // A straight line has ~zero turning angle everywhere.
        for pt in f { #expect(abs(pt.curvature) <= 1e-5) }
    }

    @Test func rejectsTooFewPoints() {
        #expect(throws: (any Error).self) {
            try pre.process(points: [Point(x: 1, y: 1)])
        }
    }

    @Test func rejectsDuplicatePointsAsDegenerate() {
        let dup = [Point(x: 3, y: 3), Point(x: 3, y: 3), Point(x: 3, y: 3)]
        #expect(throws: (any Error).self) {
            try pre.process(points: dup)
        }
    }

    private func expectPoint(_ p: StrokePoint, _ d: Float, _ c: Float, _ s: Float,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(p.distance - d) <= 1e-3, sourceLocation: sourceLocation)
        #expect(abs(p.cosTheta - c) <= 1e-3, sourceLocation: sourceLocation)
        #expect(abs(p.sinTheta - s) <= 1e-3, sourceLocation: sourceLocation)
    }
}
