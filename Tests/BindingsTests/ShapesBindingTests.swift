import XCTest
import Foundation
import DesertAnt
import TestSupport
@_spi(ShapesBindings) @testable import Shapes

/// Shapes' half of the cross-language binding: the stroke payload a host encodes
/// and the shape payload it decodes. Worth pinning on its own because shapes is
/// the first model whose input is geometry rather than text or audio - proof that
/// a new modality is a payload schema, not a new entry point in every language.
final class ShapesBindingTests: XCTestCase {
#if !os(WASI)
    private func requireModelBacked() throws {
        try XCTSkipUnless(runsModelBackedTests, "model-backed tests do not run on iOS or Android")
    }

    /// A recognizer over the cached model, reached through the binding only.
    private func recognizer() -> Shapes { Shapes() }

    /// `u32 count`, then `f64 x`, `f64 y` per point.
    private func stroke(_ points: [Point]) -> FFIReader {
        var w = FFIWriter()
        w.u32(points.count)
        for p in points {
            w.f64(p.x)
            w.f64(p.y)
        }
        return FFIReader(w.bytes)
    }

    private func options(minimumConfidence: Double) -> FFIReader {
        var w = FFIWriter()
        w.f64(minimumConfidence)
        return FFIReader(w.bytes)
    }

    /// The geometry payload contract: a stroke in through the generic
    /// `run(input:options:)` entry, a fitted shape out, decoded with the same
    /// reader a host uses.
    func testStrokePayloadRoundTrip() async throws {
        try requireModelBacked()
        guard let payload = await recognizer().run(
            input: stroke(ShapesTestStrokes.circle()), options: FFIReader([])) else {
            return XCTFail("the geometry binding returned no payload")
        }
        var reader = FFIReader(payload)
        XCTAssertEqual(reader.u32(), 1, "expected a recognized shape")
        XCTAssertEqual(reader.u32(), 4, "expected the ellipse kind")
        XCTAssertEqual(reader.f64(), 100, accuracy: 8)   // center x
        XCTAssertEqual(reader.f64(), 100, accuracy: 8)   // center y
        XCTAssertEqual(reader.f64(), 80, accuracy: 12)   // semi-major
        XCTAssertEqual(reader.f64(), 80, accuracy: 12)   // semi-minor
        _ = reader.f64()                                 // rotation
        XCTAssertTrue(reader.isAtEnd, "the ellipse payload is fully consumed")
    }

    /// A rejected stroke is a result, not a failure: the host gets a payload
    /// whose `present` flag is 0 rather than a NULL buffer, which is how it tells
    /// "no shape here" apart from "the model could not run".
    func testRejectedStrokeIsAPayloadNotAFailure() async throws {
        try requireModelBacked()
        guard let payload = await recognizer().run(
            input: stroke(ShapesTestStrokes.circle()),
            options: options(minimumConfidence: 1)) else {
            return XCTFail("a rejected stroke must still return a payload")
        }
        var reader = FFIReader(payload)
        XCTAssertEqual(reader.u32(), 0)
        XCTAssertTrue(reader.isAtEnd, "nothing follows a 0 present flag")
    }

    /// An empty options payload means the SDK defaults, which for shapes is
    /// `minimumConfidence: 0` - the same stroke the explicit `1` above rejected.
    func testEmptyOptionsMeansTheSDKDefaults() async throws {
        try requireModelBacked()
        guard let payload = await recognizer().run(
            input: stroke(ShapesTestStrokes.circle()), options: FFIReader([])) else {
            return XCTFail("the geometry binding returned no payload")
        }
        var reader = FFIReader(payload)
        XCTAssertEqual(reader.u32(), 1)
    }

    /// A truncated buffer is untrusted foreign input. Every `FFIReader` read is
    /// bounds-checked and yields a default on underflow, so a host that lies
    /// about its point count gets a well-defined answer instead of a trap.
    func testTruncatedStrokePayloadDoesNotTrap() async throws {
        try requireModelBacked()
        var w = FFIWriter()
        w.u32(64)             // claims 64 points
        w.f64(1)              // supplies half of one; the rest underflow to 0
        guard let payload = await recognizer().run(
            input: FFIReader(w.bytes), options: FFIReader([])) else {
            return XCTFail("a malformed stroke must still return a payload")
        }
        var reader = FFIReader(payload)
        XCTAssertTrue([0, 1].contains(reader.u32()), "present is a 0/1 flag")
    }

    /// An empty input payload is the degenerate case of the same rule: no points
    /// at all is a rejected stroke, not a failed run.
    func testEmptyStrokePayloadIsRejected() async throws {
        try requireModelBacked()
        guard let payload = await recognizer().run(
            input: FFIReader([]), options: FFIReader([])) else {
            return XCTFail("an empty stroke must still return a payload")
        }
        var reader = FFIReader(payload)
        XCTAssertEqual(reader.u32(), 0)
    }

    func testShapesOwnsOnlyItsCatalogId() {
        XCTAssertEqual(ShapesBinding.id, "shapes")
    }
#endif
}

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
}
