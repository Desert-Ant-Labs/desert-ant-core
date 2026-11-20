import Testing
import Foundation
import DesertAnt
import TestSupport
@_spi(ShapesBindings) @testable import Shapes

/// Shapes' half of the cross-language binding: the drawing payload a host encodes
/// and the shape payload it decodes. Worth pinning on its own because shapes is
/// the first model whose input is geometry rather than text or audio - proof that
/// a new modality is a payload schema, not a new entry point in every language.
#if !os(WASI)
// Serialized like every other model-backed suite: the tests each build a
// `Shapes()` and its LiteRT session, and concurrent session creation races
// LiteRT's global registry (the run intermittently returns a NULL buffer,
// which the binding surfaces as a nil payload and the contract tests reject).
@Suite(.serialized, .modelBacked)
struct ShapesBindingTests {
    /// A recognizer over the cached model, reached through the binding only.
    private func recognizer() -> Shapes { Shapes() }

    /// One stroke without times: `u32 1` stroke, `u32 count`, `u32 0`, then
    /// `f64 x`, `f64 y` per point.
    private func stroke(_ points: [Point]) -> FFIReader {
        drawing([(points, [])])
    }

    /// `u32 strokes`, then per stroke `u32 count`, `u32 timed`, and `f64 x`,
    /// `f64 y` (and `f64 t` when timed) per point.
    private func drawing(_ strokes: [([Point], [Double])]) -> FFIReader {
        var w = FFIWriter()
        w.u32(strokes.count)
        for (points, times) in strokes {
            let timed = times.count == points.count
            w.u32(points.count)
            w.u32(timed ? 1 : 0)
            for (i, p) in points.enumerated() {
                w.f64(p.x)
                w.f64(p.y)
                if timed { w.f64(times[i]) }
            }
        }
        return FFIReader(w.bytes)
    }

    private func options(minimumConfidence: Double, rotation: Int? = nil, kinds: Int? = nil,
                         finished: Int? = nil) -> FFIReader {
        var w = FFIWriter()
        w.f64(minimumConfidence)
        if let rotation { w.u32(rotation) }
        if let kinds { w.u32(kinds) }
        if let finished { w.u32(finished) }
        return FFIReader(w.bytes)
    }

    /// A parity drawing's strokes with their times, from the Shapes fixture.
    private func parityDrawing(_ name: String) throws -> FFIReader {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/shapes-v2-parity.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try #require(json["cases"] as? [[String: Any]])
        let c = try #require(cases.first { $0["name"] as? String == name })
        let strokes = try #require(c["strokes"] as? [[[Double]]])
        return drawing(strokes.map { s in (s.map { Point(x: $0[0], y: $0[1]) }, s.map { $0[2] }) })
    }

    private func outline(_ reader: inout FFIReader) -> Int {
        let n = reader.u32()
        for _ in 0..<(2 * n) { _ = reader.f64() }
        return n
    }

    /// The geometry payload contract: a stroke in through the generic
    /// `run(input:options:)` entry, a fitted shape out, decoded with the same
    /// reader a host uses.
    @Test func strokePayloadRoundTrip() async throws {
        let payload = try #require(
            await recognizer().run(input: stroke(ShapesTestStrokes.circle()), options: FFIReader([])),
            "the geometry binding returned no payload")
        var reader = FFIReader(payload)
        #expect(reader.u32() == 1, "expected a recognized shape")
        #expect(reader.u32() == 4, "expected the ellipse kind")
        #expect(abs(reader.f64() - 100) <= 4)    // center x
        #expect(abs(reader.f64() - 100) <= 4)    // center y
        #expect(abs(reader.f64() - 80) <= 4)     // semi-major
        #expect(abs(reader.f64() - 80) <= 4)     // semi-minor
        _ = reader.f64()                         // rotation
        #expect(outline(&reader) == wireOutlineSamples, "every shape ends with its outline")
        #expect(reader.isAtEnd, "the ellipse payload is fully consumed")
    }

    /// A drawing of two timed strokes, a level one and then an upright one
    /// across it, comes back as a plus (wire kind 19) with its two strokes.
    @Test func twoTimedStrokesMakeAPlus() async throws {
        let across = ShapesTestStrokes.segment(from: Point(x: 20, y: 100), to: Point(x: 180, y: 100))
        let down = ShapesTestStrokes.segment(from: Point(x: 100, y: 20), to: Point(x: 100, y: 180))
        let first = (0..<across.count).map { Double($0) * 16 }
        let second = (0..<down.count).map { 600 + Double($0) * 16 }
        let payload = try #require(
            await recognizer().run(input: drawing([(across, first), (down, second)]), options: FFIReader([])),
            "the geometry binding returned no payload")
        var reader = FFIReader(payload)
        #expect(reader.u32() == 1, "expected a recognized shape")
        #expect(reader.u32() == 19, "expected the plus kind")
        for _ in 0..<8 { _ = reader.f64() }      // the two strokes' ends
        #expect(outline(&reader) >= 4, "a plus ends with its outline: the first stroke, then the second")
        #expect(reader.isAtEnd, "the plus payload is fully consumed")
    }

    /// The kinds mask has bit n for wire kind n. With the ellipse (4) left out,
    /// Shapes returns no shape for a circle. With the ellipse in, Shapes returns
    /// the ellipse.
    @Test func kindsMaskFiltersTheResult() async throws {
        let without = try #require(await recognizer().run(
            input: stroke(ShapesTestStrokes.circle()),
            options: options(minimumConfidence: 0, rotation: 0, kinds: (1 << 1) | (1 << 2))))
        var r = FFIReader(without)
        #expect(r.u32() == 0)
        let with = try #require(await recognizer().run(
            input: stroke(ShapesTestStrokes.circle()),
            options: options(minimumConfidence: 0, rotation: 2, kinds: 1 << 4)))
        r = FFIReader(with)
        #expect(r.u32() == 1 && r.u32() == 4)
    }

    /// The last options field is `finished`: a half-drawn ellipse is refused
    /// as undrawn when finished (the default) and comes back for a preview
    /// when not, so Kotlin and JavaScript reach `Options.isFinished` too.
    @Test func finishedFlagReachesTheOptions() async throws {
        let finished = try #require(await recognizer().run(
            input: try parityDrawing("ellipse_half"), options: options(minimumConfidence: 0, rotation: 2, kinds: 0, finished: 1)))
        var reader = FFIReader(finished)
        #expect(reader.u32() == 0, "a half-drawn ellipse waits for its outline when finished")
        let preview = try #require(await recognizer().run(
            input: try parityDrawing("ellipse_half"), options: options(minimumConfidence: 0, rotation: 2, kinds: 0, finished: 0)))
        reader = FFIReader(preview)
        #expect(reader.u32() == 1 && reader.u32() == wireKinds[.ellipse], "a preview does not wait")
    }

    /// Every kind has its own wire number, and the numbers never change.
    @Test func wireKindsAreStable() {
        #expect(Set(wireKinds.keys) == Set(Shape.Kind.allCases))
        #expect(Set(wireKinds.values).count == Shape.Kind.allCases.count)
        #expect(wireKinds[.line] == 1 && wireKinds[.rectangle] == 2 && wireKinds[.triangle] == 3
            && wireKinds[.ellipse] == 4 && wireKinds[.star] == 5)
    }

    /// A rejected stroke is a result, not a failure: the host gets a payload
    /// whose `present` flag is 0 rather than a NULL buffer, which is how it tells
    /// "no shape here" apart from "the model could not run".
    @Test func rejectedStrokeIsAPayloadNotAFailure() async throws {
        let payload = try #require(
            await recognizer().run(
                input: stroke(ShapesTestStrokes.circle()),
                options: options(minimumConfidence: 1)),
            "a rejected stroke must still return a payload")
        var reader = FFIReader(payload)
        #expect(reader.u32() == 0)
        #expect(reader.isAtEnd, "nothing follows a 0 present flag")
    }

    /// An empty options payload means the SDK defaults: `minimumConfidence` 0,
    /// snapped rotation, and every kind. Shapes recognizes the stroke that a
    /// `minimumConfidence` of 1 rejected above.
    @Test func emptyOptionsMeansTheSDKDefaults() async throws {
        let payload = try #require(
            await recognizer().run(input: stroke(ShapesTestStrokes.circle()), options: FFIReader([])),
            "the geometry binding returned no payload")
        var reader = FFIReader(payload)
        #expect(reader.u32() == 1)
    }

    /// A truncated buffer is untrusted foreign input. Every `FFIReader` read is
    /// bounds-checked and yields a default on underflow, so a host that lies
    /// about its point count gets a well-defined answer instead of a trap.
    @Test func truncatedStrokePayloadDoesNotTrap() async throws {
        var w = FFIWriter()
        w.u32(1)              // one stroke
        w.u32(64)             // claims 64 points
        w.u32(0)              // without times
        w.f64(1)              // supplies half of one
        let payload = try #require(
            await recognizer().run(input: FFIReader(w.bytes), options: FFIReader([])),
            "a malformed stroke must still return a payload")
        var reader = FFIReader(payload)
        #expect([0, 1].contains(reader.u32()), "present is a 0/1 flag")
    }

    /// An empty input payload is the degenerate case of the same rule: no points
    /// at all is a rejected stroke, not a failed run.
    @Test func emptyStrokePayloadIsRejected() async throws {
        let payload = try #require(
            await recognizer().run(input: FFIReader([]), options: FFIReader([])),
            "an empty stroke must still return a payload")
        var reader = FFIReader(payload)
        #expect(reader.u32() == 0)
    }

    @Test func shapesOwnsOnlyItsCatalogId() {
        #expect(ShapesBinding.id == "shapes")
    }
}
#endif

/// Strokes for the binding suite. `ShapesTests` has its own copies in the Shapes
/// test target, which this target cannot see.
enum ShapesTestStrokes {
    static func circle(center: Point = Point(x: 100, y: 100), radius: Double = 80,
                       samples: Int = 64) -> [Point] {
        (0...samples).map { i in
            let t = 2 * Double.pi * Double(i) / Double(samples)
            return Point(x: center.x + radius * cos(t), y: center.y + radius * sin(t))
        }
    }

    static func segment(from a: Point, to b: Point, samples: Int = 24) -> [Point] {
        (0...samples).map { i in
            let t = Double(i) / Double(samples)
            return Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }
}
