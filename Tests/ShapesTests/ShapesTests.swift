import Foundation
import Testing
import DesertAnt
import TestSupport
@_spi(ShapesDiagnostics) @testable import Shapes

/// Recognition through the downloaded model: the Core ML file on Apple
/// platforms and the LiteRT file on Linux and Windows. Both files come from the
/// same checkpoint and have the same tensors, so the results match, except on
/// a near tie, where the two quantized builds can rank the top two kinds apart:
/// each platform is checked against its own build's reading of the parity
/// drawings (`InkParityTests.Case.ownTop`).
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

        /// v1 read this stroke as a scribble (the erase gesture). v2 has a zigzag
        /// kind of its own.
        /// Untrusted coordinates from a binding: a stroke reaching 1e200, or
        /// holding an infinity or a NaN, comes back nil, never a crash
        /// (Greptile on #168).
        @Test func coordinatesFarOffAnyCanvasAreRefused() async throws {
            let shapes = makeShapes()
            for far in [1e200, .infinity, .nan] {
                let seen = try await shapes.inspect(strokes: [Stroke(points: [Point(x: 0, y: 0), Point(x: far, y: 0)])])
                #expect(seen.shape == nil && seen.rejection == .invalid, "\(far)")
            }
        }

        @Test func zigzagIsAZigzag() async throws {
            let model = try await makeShapes().loadedModel()
            let stroke = ShapesTests.zigzag().enumerated().map { InkPoint(x: $1.x, y: $1.y, t: Double($0) * 8) }
            let reading = try #require(try await model.read([stroke]))
            #expect(reading.kind == "zigzag")
            guard case .zigzag? = try await makeShapes().recognize(points: ShapesTests.zigzag()) else {
                Issue.record("expected a zigzag"); return
            }
        }

        /// On the parity drawings, the downloaded file gives the top kind of the
        /// same build run on the CPU, with its probability within 0.05 of it:
        /// the Core ML build on Apple platforms (the compute unit here may
        /// differ), the LiteRT build elsewhere. The two builds' weights are
        /// quantized differently, so each platform is checked against its own:
        /// on a near tie the two builds can rank the top two kinds apart.
        @Test func agreesWithTheReferenceModel() async throws {
            let model = try await makeShapes().loadedModel()
            var agree = 0
            for c in InkParityTests.cases {
                let reading = try #require(try await model.read(c.strokes))
                let logits = c.ownLogits
                let peak = logits.max()!
                let exps = logits.map { Foundation.exp(Double($0 - peak)) }
                let ref = exps.map { $0 / exps.reduce(0, +) }
                let refTop = ref.indices.max { ref[$0] < ref[$1] }!
                if reading.top == refTop { agree += 1 }
                #expect(abs(Double(reading.probs[reading.top]) - ref[reading.top]) <= 0.05, "\(c.name): probability drifted")
            }
            #expect(InkParityTests.cases.count >= 20 && agree == InkParityTests.cases.count,
                    "agreed on \(agree) of \(InkParityTests.cases.count)")
        }

        /// Every parity drawing, its strokes and times handed over as an app
        /// would, comes back as its kind (a line may come back as a curve). A
        /// half-drawn outline is read as its kind but does not snap: a half
        /// rectangle or ellipse comes back `nil`, rejected as undrawn. A check
        /// has no outline to finish, so a half check snaps as a check. The
        /// first half of an arrow is its shaft, with no head drawn yet, so it
        /// may come back as a line or a curve. Where this platform's build
        /// reads another kind on top (a near tie; v2.2.0's LiteRT build reads
        /// the half rectangle as a check, 0.385 over 0.377), the SDK's reading
        /// is that kind.
        @Test func parityDrawingsComeBackAsTheirKind() async throws {
            let shapes = makeShapes()
            var misses: [String] = []
            for c in InkParityTests.cases {
                let strokes = c.strokes.map { Stroke(points: $0.map { Point(x: $0.x, y: $0.y) }, times: $0.map(\.t)) }
                let seen = try await shapes.inspect(strokes: strokes, options: Options(rotation: .free))
                let kind = seen.shape?.kind
                let want: Set<Shape.Kind> = c.label == "line" ? [.line, .curve]
                    : c.name == "arrow_half" ? [.arrow, .line, .curve] : [Shape.Kind(rawValue: c.label)!]
                let own = c.ownTop ?? c.label
                if own != c.label, Shape.Kind(rawValue: own).map({ !want.contains($0) }) ?? true {
                    if seen.kinds.first?.name != own {
                        misses.append("\(c.name): read \(seen.kinds.first?.name ?? "-"), its build reads \(own)")
                    }
                } else if ["rectangle_half", "ellipse_half"].contains(c.name) {
                    if kind != nil || seen.rejection != .undrawn || seen.kinds.first?.name != c.label {
                        misses.append("\(c.name): \(kind.map { "\($0)" } ?? "nil"), \(seen.rejection.map { "\($0)" } ?? "no rejection")")
                    }
                } else if kind == nil || !want.contains(kind!) {
                    misses.append("\(c.name): \(kind.map { "\($0)" } ?? "nil")")
                }
            }
            #expect(misses.isEmpty, "\(misses)")
        }

        /// While the pen still moves (`isFinished: false`), a half-drawn
        /// outline is not waited for: the half rectangle and ellipse come back as
        /// the shapes they are becoming, for a preview. A half outline this
        /// platform's build reads as another kind (a near tie) has no outline
        /// to preview, so it is left out; at least one stays.
        @Test func aPreviewDoesNotWaitForTheOutline() async throws {
            let shapes = makeShapes()
            var checked = 0
            for c in InkParityTests.cases where ["rectangle_half", "ellipse_half"].contains(c.name) && c.ownTop == c.label {
                checked += 1
                let strokes = c.strokes.map { Stroke(points: $0.map { Point(x: $0.x, y: $0.y) }, times: $0.map(\.t)) }
                let seen = try await shapes.inspect(strokes: strokes, options: Options(rotation: .free, isFinished: false))
                #expect(seen.shape != nil && seen.rejection == nil, "\(c.name): \(seen.rejection.map { "\($0)" } ?? "no shape")")
                #expect(seen.undrawn.map { $0 > 0.15 } == true, "\(c.name) is half drawn")
            }
            #expect(checked >= 1, "no half outline this platform's build reads as drawn")
        }

        /// Open marks have no outline to finish: a check with a short first arm,
        /// drawn whole on a trackpad (Berkay, 2026-11-14; 17% of its fitted
        /// template measured undrawn and it was refused before open marks were
        /// left out of the gate), snaps; no open mark waits for an outline.
        @Test func completeOpenMarksSnap() async throws {
            let shapes = makeShapes()
            let marks: [(Shape.Kind, [[(Double, Double, Double)]])] = [
                (.check, [[(711.7, 660.3, 0), (711.7, 660.2, 4), (711.7, 660.4, 158), (711.7, 661.5, 167), (712.0, 662.8, 175), (712.7, 664.4, 183), (713.9, 666.6, 192), (715.0, 668.6, 198), (715.6, 670.3, 205), (716.3, 672.4, 213), (717.1, 674.0, 222), (717.6, 675.4, 230), (718.2, 677.0, 238), (718.7, 678.2, 247), (719.1, 679.3, 255), (719.4, 680.3, 263), (719.7, 681.3, 272), (720.0, 682.0, 280), (720.2, 682.5, 289), (720.3, 682.9, 296), (720.6, 683.4, 305), (720.9, 683.8, 313), (721.1, 684.1, 321), (721.3, 684.3, 330), (721.4, 684.5, 347), (721.6, 684.5, 372), (721.9, 684.5, 383), (722.1, 684.5, 392), (722.3, 684.5, 408), (722.6, 684.5, 417), (722.8, 684.4, 425), (723.1, 684.0, 433), (723.5, 683.2, 442), (724.3, 681.9, 450), (725.7, 680.4, 458), (727.7, 678.4, 467), (730.1, 675.8, 475), (733.1, 673.0, 483), (736.4, 669.8, 492), (740.2, 666.3, 500), (744.0, 662.8, 508), (747.5, 659.5, 517), (751.0, 656.5, 525), (753.5, 654.4, 533), (755.3, 652.8, 542), (757.4, 650.9, 550), (759.4, 649.4, 558), (761.1, 647.8, 567), (762.6, 646.5, 575), (763.6, 645.8, 580), (764.2, 645.2, 588), (765.0, 644.4, 597), (765.7, 643.7, 605), (766.6, 642.7, 614), (767.4, 641.9, 622), (767.9, 641.2, 630), (768.4, 640.4, 638), (768.4, 640.4, 650)]]),
            ]
            for (want, ink) in marks {
                let strokes = ink.map { s in Stroke(points: s.map { Point(x: $0.0, y: $0.1) }, times: s.map { $0.2 }) }
                let seen = try await shapes.inspect(strokes: strokes, options: Options(rotation: .upright))
                #expect(seen.shape?.kind == want, "\(want): \(seen.rejection.map { "\($0)" } ?? "no rejection"), top \(seen.kinds.first?.name ?? "-")")
            }
            let open: Set<Shape.Kind> = [.line, .curve, .arrow, .check, .cross, .plus, .bracket, .zigzag, .scribble]
            #expect(Model.outlines.isDisjoint(with: open))
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


extension InkParityTests.Case {
    /// The logits of the build this platform runs, on the CPU: Core ML on
    /// Apple platforms, LiteRT elsewhere.
    var ownLogits: [Float] { ModelPlatform.current == .apple ? coremlLogits : (litertLogits ?? coremlLogits) }

    /// The kind that build reads on top. The two builds' weights are quantized
    /// differently, so on a near tie they can rank the top two kinds apart.
    var ownTop: String? {
        guard let kinds = InkParityTests.meta?.kinds,
              let i = ownLogits.indices.max(by: { ownLogits[$0] < ownLogits[$1] }) else { return nil }
        return kinds[i]
    }
}
