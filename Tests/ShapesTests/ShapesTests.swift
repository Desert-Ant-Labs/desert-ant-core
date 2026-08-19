import Foundation
import XCTest
import DesertAnt
import TestSupport
@testable import Shapes

/// End-to-end recognition through the downloaded model. On Apple this runs the
/// Core ML artifact; on Linux/Windows the LiteRT artifact (via LiteRT). Both
/// exports come from the same checkpoint and share one fixed-window signature, so
/// the results match.
final class ShapesTests: XCTestCase {
    // The model-backed tests are wasm-guarded because the shared fixture does not
    // exist there (the model store's filesystem and transport come from the JS host
    // the app installs, which the bare test harness never does), and skipped off
    // iOS/Android by `requireModelBacked`.
#if !os(WASI)
    /// Skip unless this is a platform where model-backed tests run.
    private func requireModelBacked() throws {
        try XCTSkipUnless(runsModelBackedTests, "model-backed tests do not run on iOS or Android")
    }

    /// A recognizer over the cached model (offline after the fixture's download).
    private func makeShapes() -> Shapes { Shapes() }

    func testRecognizesCircleAsEllipseWithFit() async throws {
        try requireModelBacked()
        let recognized = try await makeShapes().recognize(points: Self.circle())
        let shape = try XCTUnwrap(recognized)
        guard case let .ellipse(center, major, minor, _) = shape else {
            return XCTFail("expected ellipse geometry, got \(shape)")
        }
        XCTAssertEqual(center.x, 100, accuracy: 8)
        XCTAssertEqual(center.y, 100, accuracy: 8)
        XCTAssertEqual(major, 80, accuracy: 12)
        XCTAssertEqual(minor, 80, accuracy: 12)
    }

    func testRecognizesLineWithEndpoints() async throws {
        try requireModelBacked()
        let recognized = try await makeShapes().recognize(points: Self.diagonal())
        let shape = try XCTUnwrap(recognized)
        guard case let .line(a, b) = shape else {
            return XCTFail("expected line geometry, got \(shape)")
        }
        XCTAssertGreaterThan(hypot(a.x - b.x, a.y - b.y), 100)
    }

    func testRecognizesTriangle() async throws {
        try requireModelBacked()
        let traced = Self.polygon([
            Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 50, y: 90),
        ])
        let recognized = try await makeShapes().recognize(points: traced)
        let shape = try XCTUnwrap(recognized)
        guard case let .triangle(vertices) = shape else {
            return XCTFail("expected triangle geometry, got \(shape)")
        }
        XCTAssertEqual(vertices.count, 3)
    }

    /// A stroke too short to mean anything is rejected before the model runs.
    func testDegenerateReturnsNil() async throws {
        try requireModelBacked()
        let result = try await makeShapes().recognize(points: [Point(x: 1, y: 1)])
        XCTAssertNil(result)
    }

    /// `minimumConfidence` raises the bar on top of each class's calibrated gate,
    /// so `1` rejects everything the model could ever propose.
    func testMinimumConfidenceRejects() async throws {
        try requireModelBacked()
        let options = Options(minimumConfidence: 1)
        let result = try await makeShapes().recognize(points: Self.circle(), options: options)
        XCTAssertNil(result)
    }

    /// A model directory the user populated is adopted offline, with no download.
    func testPrepopulatedDirectoryIsAdopted() async throws {
        try requireModelBacked()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shapes-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await ModelFixture.populate(ShapesModel.self, into: directory)

        let shapes = Shapes(directory: directory.path)
        XCTAssertTrue(shapes.isDownloaded())
        guard case .ellipse = try await shapes.recognize(points: Self.circle()) else {
            return XCTFail("expected an ellipse from the adopted directory")
        }
    }
#endif

    // MARK: strokes

    /// A traced circle, dense enough to look hand-drawn to the preprocessor.
    static func circle(center: Point = Point(x: 100, y: 100), radius: Double = 80,
                       samples: Int = 64) -> [Point] {
        (0...samples).map { i in
            let t = 2 * Double.pi * Double(i) / Double(samples)
            return Point(x: center.x + radius * cos(t), y: center.y + radius * sin(t))
        }
    }

    static func diagonal() -> [Point] {
        (0...40).map { Point(x: Double($0) * 5, y: Double($0) * 2) }
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
        return points
    }
}
