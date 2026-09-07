import Foundation
import Testing
import DesertAnt
import TestSupport
@testable import Shapes

/// End-to-end recognition through the downloaded model. On Apple this runs the
/// Core ML artifact; on Linux/Windows the LiteRT artifact (via LiteRT). Both
/// exports come from the same checkpoint and share one fixed-window signature, so
/// the results match.
///
/// The model-backed tests are wasm-guarded because the shared fixture does not
/// exist there (the model store's filesystem and transport come from the JS host
/// the app installs, which the bare test harness never does), and skipped off
/// iOS/Android by the `.modelBacked` trait. `.serialized` keeps the instances
/// from resolving the same model concurrently, the house pattern for model
/// suites (see Ear's SmokeTests).
struct ShapesTests {
#if !os(WASI)
    @Suite(.serialized, .modelBacked)
    struct ModelTests {
        /// A recognizer over the cached model (offline after the fixture's download).
        private func makeShapes() -> Shapes { Shapes() }

        @Test func recognizesCircleAsEllipseWithFit() async throws {
            let recognized = try await makeShapes().recognize(points: ShapesTests.circle())
            let shape = try #require(recognized)
            guard case let .ellipse(center, major, minor, _) = shape else {
                Issue.record("expected ellipse geometry, got \(shape)")
                return
            }
            #expect(abs(center.x - 100) <= 8)
            #expect(abs(center.y - 100) <= 8)
            #expect(abs(major - 80) <= 12)
            #expect(abs(minor - 80) <= 12)
        }

        @Test func recognizesLineWithEndpoints() async throws {
            let recognized = try await makeShapes().recognize(points: ShapesTests.diagonal())
            let shape = try #require(recognized)
            guard case let .line(a, b) = shape else {
                Issue.record("expected line geometry, got \(shape)")
                return
            }
            #expect(hypot(a.x - b.x, a.y - b.y) > 100)
        }

        @Test func recognizesTriangle() async throws {
            let traced = ShapesTests.polygon([
                Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 50, y: 90),
            ])
            let recognized = try await makeShapes().recognize(points: traced)
            let shape = try #require(recognized)
            guard case let .triangle(vertices) = shape else {
                Issue.record("expected triangle geometry, got \(shape)")
                return
            }
            #expect(vertices.count == 3)
        }

        /// A stroke too short to mean anything is rejected before the model runs.
        @Test func degenerateReturnsNil() async throws {
            let result = try await makeShapes().recognize(points: [Point(x: 1, y: 1)])
            #expect(result == nil)
        }

        /// `minimumConfidence` raises the bar on top of each class's calibrated gate,
        /// so `1` rejects everything the model could ever propose.
        @Test func minimumConfidenceRejects() async throws {
            let options = Options(minimumConfidence: 1)
            let result = try await makeShapes().recognize(points: ShapesTests.circle(), options: options)
            #expect(result == nil)
        }

        /// A model directory the user populated is adopted offline, with no download.
        @Test func prepopulatedDirectoryIsAdopted() async throws {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("shapes-local-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            try await ModelFixture.populate(ShapesModel.self, into: directory)

            let shapes = Shapes(directory: directory.path)
            #expect(shapes.isDownloaded())
            let recognized = try await shapes.recognize(points: ShapesTests.circle())
            guard case .ellipse = recognized else {
                Issue.record("expected an ellipse from the adopted directory, got \(String(describing: recognized))")
                return
            }
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
