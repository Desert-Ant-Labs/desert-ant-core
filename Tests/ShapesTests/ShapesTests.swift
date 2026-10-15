import Foundation
import Testing
import DesertAnt
import TestSupport
@testable import Shapes

/// Recognition through the downloaded model: the Core ML file on Apple
/// platforms and the LiteRT file on Linux and Windows. Both files come from the
/// same checkpoint and have the same tensors, so the results match.
///
/// The model tests don't run on wasm, where the shared model fixture doesn't
/// exist. `.modelBacked` skips them on iOS and Android, and `.serialized` keeps
/// two instances from resolving the same model at once.
struct ShapesTests {
#if !os(WASI)
    @Suite(.serialized, .modelBacked)
    struct ModelTests {
        private func makeShapes() -> Shapes { Shapes() }

        @Test func circleIsAnEllipseSnappedToACircle() async throws {
            let shape = try #require(try await makeShapes().recognize(points: ShapesTests.circle()))
            guard case let .ellipse(center, major, minor, _) = shape else {
                Issue.record("expected an ellipse, got \(shape)"); return
            }
            #expect(abs(center.x - 100) <= 4 && abs(center.y - 100) <= 4)
            #expect(abs(major - 80) <= 4 && major == minor)
        }

        @Test func diagonalIsALine() async throws {
            let shape = try #require(try await makeShapes().recognize(points: ShapesTests.diagonal()))
            guard case let .line(a, b) = shape else { Issue.record("expected a line, got \(shape)"); return }
            #expect(hypot(a.x - b.x, a.y - b.y) > 180)
        }

        @Test func boxIsARectangle() async throws {
            let box = ShapesTests.polygon([Point(x: 0, y: 0), Point(x: 160, y: 0), Point(x: 160, y: 90), Point(x: 0, y: 90)])
            let shape = try #require(try await makeShapes().recognize(points: box))
            guard case let .rectangle(corners) = shape else { Issue.record("expected a rectangle, got \(shape)"); return }
            #expect(corners.count == 4)
        }

        @Test func arrowHasItsHeadAtTheEnd() async throws {
            let shape = try #require(try await makeShapes().recognize(points: ShapesTests.arrow()))
            guard case let .arrow(from, _, _, to, startHead, endHead) = shape else {
                Issue.record("expected an arrow, got \(shape)"); return
            }
            #expect(!startHead && endHead)
            #expect(abs(to.x - 200) <= 10 && abs(from.x) <= 10)
        }

        @Test func zigzagIsAScribbleUnlessLeftOut() async throws {
            let shapes = makeShapes()
            let shape = try await shapes.recognize(points: ShapesTests.zigzag())
            guard case let .scribble(hull)? = shape else { Issue.record("expected a scribble, got \(String(describing: shape))"); return }
            #expect(hull.count >= 3)
            var kinds = Set(Shape.Kind.allCases)
            kinds.remove(.scribble)
            #expect(try await shapes.recognize(points: ShapesTests.zigzag(), options: Options(kinds: kinds)) == nil)
        }

        /// On the parity strokes the trained model scored at 0.8 or above, the
        /// shipped file (Core ML fp16 on Apple platforms, LiteRT elsewhere)
        /// picks the same kind, with each probability within 0.05.
        @Test func agreesWithTheReferenceModel() async throws {
            let shapes = makeShapes()
            let model = try await shapes.loadedModel()
            var agree = 0, total = 0
            for c in ParityTests.cases where c.probs.max()! >= 0.8 {
                let (probs, _) = try await model.outputs(c.points)
                let ref = c.probs.indices.max { c.probs[$0] < c.probs[$1] }!
                let got = probs.indices.max { probs[$0] < probs[$1] }!
                total += 1
                if ref == got { agree += 1 }
                #expect(abs(Double(probs[got]) - c.probs[got]) <= 0.05, "\(c.name): probability drifted")
            }
            #expect(total >= 30 && agree == total, "agreed on \(agree) of \(total)")
        }

        @Test func degenerateAndTapsAreNil() async throws {
            let shapes = makeShapes()
            #expect(try await shapes.recognize(points: [Point(x: 1, y: 1)]) == nil)
            #expect(try await shapes.recognize(points: [Point(x: 1, y: 1), Point(x: 3, y: 2)]) == nil)
        }

        @Test func minimumConfidenceOneRejects() async throws {
            let result = try await makeShapes().recognize(points: ShapesTests.circle(), options: Options(minimumConfidence: 1))
            #expect(result == nil)
        }

        @Test func uprightRemovesRotation() async throws {
            let tilted = SnappingTests.rotated(
                ShapesTests.polygon([Point(x: 0, y: 0), Point(x: 160, y: 0), Point(x: 160, y: 90), Point(x: 0, y: 90)]),
                by: 22, about: Point(x: 80, y: 45))
            let shapes = makeShapes()
            guard case let .rectangle(free)? = try await shapes.recognize(points: tilted, options: Options(rotation: .free)),
                  case let .rectangle(upright)? = try await shapes.recognize(points: tilted, options: Options(rotation: .upright)) else {
                Issue.record("expected rectangles"); return
            }
            #expect(abs(abs(SnappingTests.angle(free[0], free[1])).truncatingRemainder(dividingBy: 90) - 22) < 3
                || abs(abs(SnappingTests.angle(free[0], free[1])).truncatingRemainder(dividingBy: 90) - 68) < 3)
            #expect(abs(SnappingTests.angle(upright[0], upright[1]).truncatingRemainder(dividingBy: 90)) < 1e-9)
        }

        @Test func prepopulatedDirectoryIsAdopted() async throws {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("shapes-local-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try await ModelFixture.populate(ShapesModel.self, into: directory)
            let shapes = Shapes(directory: directory.path)
            #expect(shapes.isDownloaded())
            guard case .ellipse? = try await shapes.recognize(points: ShapesTests.circle()) else {
                Issue.record("expected an ellipse from the adopted directory"); return
            }
        }
    }
#endif

    /// A traced circle with 65 points.
    static func circle(center: Point = Point(x: 100, y: 100), radius: Double = 80, samples: Int = 64) -> [Point] {
        (0...samples).map { i in
            let t = 2 * Double.pi * Double(i) / Double(samples)
            return Point(x: center.x + radius * cos(t), y: center.y + radius * sin(t))
        }
    }

    static func diagonal() -> [Point] {
        (0...40).map { Point(x: Double($0) * 5, y: Double($0) * 2) }
    }

    /// A shaft, then a head drawn out along one barb, back to the tip, and out along the other barb.
    static func arrow() -> [Point] {
        var pts = (0...40).map { Point(x: Double($0) * 5, y: 100) }
        let barbs = [Point(x: 170, y: 82), Point(x: 200, y: 100), Point(x: 170, y: 118)]
        var last = pts[pts.count - 1]
        for b in barbs {
            for s in 1...8 { pts.append(Point(x: last.x + (b.x - last.x) * Double(s) / 8, y: last.y + (b.y - last.y) * Double(s) / 8)) }
            last = b
        }
        return pts
    }

    static func zigzag() -> [Point] {
        let vs = (0..<8).map { Point(x: Double($0) * 18, y: $0 % 2 == 0 ? 0 : 80) }
        var pts: [Point] = []
        for i in 0..<(vs.count - 1) {
            for s in 0..<10 { pts.append(Point(x: vs[i].x + (vs[i + 1].x - vs[i].x) * Double(s) / 10, y: vs[i].y + (vs[i + 1].y - vs[i].y) * Double(s) / 10)) }
        }
        return pts + [vs[vs.count - 1]]
    }

    /// Trace a closed polygon densely.
    static func polygon(_ vertices: [Point], per: Int = 24) -> [Point] {
        var points: [Point] = []
        let loop = vertices + [vertices[0]]
        for k in 0..<(loop.count - 1) {
            let a = loop[k], b = loop[k + 1]
            for s in 0..<per {
                let t = Double(s) / Double(per)
                points.append(Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return points + [vertices[0]]
    }
}
