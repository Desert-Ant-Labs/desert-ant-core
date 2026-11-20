import Foundation
import Testing
@testable import Shapes

/// The undrawn share: how much of a fitted outline is far from any ink. A
/// finished outline has next to none; a ⊓ fitted as a rectangle has its fourth
/// side undrawn and does not snap.
struct UndrawnTests {
    static func stroke(_ corners: [(Double, Double)], perSide: Int = 20) -> [InkPoint] {
        var out: [InkPoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            for k in 0..<perSide {
                let u = Double(k) / Double(perSide)
                out.append(InkPoint(x: a.0 + (b.0 - a.0) * u, y: a.1 + (b.1 - a.1) * u, t: Double(out.count) * 16))
            }
        }
        let last = corners[corners.count - 1]
        out.append(InkPoint(x: last.0, y: last.1, t: Double(out.count) * 16))
        return out
    }

    static let square = Shape.rectangle(corners: [Point(x: 0, y: 0), Point(x: 100, y: 0),
                                                 Point(x: 100, y: 100), Point(x: 0, y: 100)])

    /// A release tunes the undrawn limit per kind in its meta (weights v2.1.1:
    /// stars and hexagons 0.3, measured on validation ink); a kind it does not
    /// name keeps `Model.maximumUndrawn`.
    @Test func theMetaTunesTheLimitPerKind() throws {
        func meta(_ extra: String) throws -> ShapeMeta {
            try ShapeMeta(json: """
            {"kinds": ["star", "none"], "reject_kinds": ["none"], "n_points": 256, "max_strokes": 32,
             "outputs": {"kind_logits": [1, 2], "numbers": [1, 6]}, "numbers": {"kinds": {}},
             "resid_gates": {"star": 0.14}\(extra)}
            """)
        }
        #expect(try meta("").undrawnLimits.isEmpty)
        #expect(try meta(#", "undrawn_limits": {"star": 0.3}"#).undrawnLimits == ["star": 0.3])
    }

    /// The distance is to the ink's segments: a square given only as its five
    /// corner points is as drawn as a dense one (Greptile on #168).
    @Test func aSquareGivenAsItsCornersIsDrawn() {
        let ink = [Self.stroke([(0, 0), (100, 0), (100, 100), (0, 100), (0, 0)], perSide: 1)]
        #expect(ink[0].count == 5)
        #expect(Model.undrawn(Self.square, ink: ink) == 0)
    }

    /// A zigzag keeps the side it starts on: the fitted amplitude's sign goes
    /// through to the shape, so its outline is the one the fit checked.
    @Test func aZigzagKeepsTheSideItStartsOn() throws {
        let v = [0.0, 0.0, 100.0, 0.0, -20.0, 2.0]
        let shape = try #require(Model.shape("zigzag", v, ink: [], center: V2(0, 0), scale: 1, frame: v))
        guard case let .zigzag(_, _, amplitude, _) = shape else { Issue.record("expected a zigzag"); return }
        #expect(amplitude == -20)
        #expect(shape.outline()[0].y == 10)   // starts on the right of travel (y down)
    }

    @Test func aFinishedOutlineHasNoneUndrawn() {
        let ink = [Self.stroke([(0, 0), (100, 0), (100, 100), (0, 100), (0, 0)])]
        #expect(Model.undrawn(Self.square, ink: ink) == 0)
    }

    @Test func aSquareMissingItsBottomIsNotFinished() {
        // ⊓: left side up, top, right side down
        let ink = [Self.stroke([(0, 100), (0, 0), (100, 0), (100, 100)])]
        let gap = Model.undrawn(Self.square, ink: ink)
        #expect(gap > Model.maximumUndrawn)
        #expect(gap > 0.15 && gap < 0.25)
    }

    @Test func aHexagonMissingOneSideSnapsMissingTwoDoesNot() {
        let vs = (0..<6).map { i -> Point in
            let a = Double.pi / 3 * Double(i)
            return Point(x: 50 + 50 * Double.cos(a), y: 50 + 50 * Double.sin(a))
        }
        let hexagon = Shape.hexagon(vertices: vs)
        let six = [Self.stroke((vs + [vs[0]]).map { ($0.x, $0.y) })]
        let five = [Self.stroke(vs.map { ($0.x, $0.y) })]               // the sixth side left open
        let four = [Self.stroke(Array(vs.prefix(5)).map { ($0.x, $0.y) })]
        #expect(Model.undrawn(hexagon, ink: six) == 0)
        // the open side's ends lie near the ink: 9 of 96 points are far (ml-shapes' fitter measures the same)
        #expect(abs(Model.undrawn(hexagon, ink: five) - 0.09375) < 1e-9)
        #expect(Model.undrawn(hexagon, ink: four) > Model.maximumUndrawn)
    }

    @Test func twoStrokesCountAsOneInk() {
        // a cross drawn as its two strokes covers both of its outlines
        let cross = Shape.cross(firstFrom: Point(x: 0, y: 0), firstTo: Point(x: 100, y: 100),
                                secondFrom: Point(x: 100, y: 0), secondTo: Point(x: 0, y: 100))
        let both = [Self.stroke([(0, 0), (100, 100)]), Self.stroke([(100, 0), (0, 100)])]
        let one = [Self.stroke([(0, 0), (100, 100)])]
        #expect(Model.undrawn(cross, ink: both) == 0)
        #expect(Model.undrawn(cross, ink: one) > 0.3)
    }
}
