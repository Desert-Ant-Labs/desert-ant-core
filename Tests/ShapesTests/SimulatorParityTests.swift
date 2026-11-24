#if os(iOS) && targetEnvironment(simulator)
import Foundation
import Shapes
import Testing
import TestSupport

@Suite(.enabled(if: ProcessInfo.processInfo.environment["DAL_IOS_SHAPES_MODEL_DIR"] != nil,
                "stage the pinned Shapes Core ML export and set DAL_IOS_SHAPES_MODEL_DIR"))
struct ShapesSimulatorParityTests {
    @Test func inkMatchesStagedAppleModel() async throws {
        try await withStagedSimulatorModel("Shapes", environmentKey: "DAL_IOS_SHAPES_MODEL_DIR",
                                           entry: ShapesModel.directory(for: .apple)) { directory in
            let shapes = Shapes(directory: directory)
            try #require(shapes.isDownloaded(), "the staged Core ML artifact and sidecar were not adopted")
            for name in ["plus", "ellipse", "ellipse_half"] {
                let row = try #require(InkParityTests.cases.first { $0.name == name })
                let strokes = row.timedStrokes
                let shape = try await shapes.recognize(strokes: strokes, options: .init(rotation: .free))
                if name == "ellipse_half" {
                    #expect(shape == nil)
                    let preview = try await shapes.recognize(
                        strokes: strokes, options: .init(rotation: .free, isFinished: false))
                    #expect(preview?.kind.rawValue == row.top)
                } else {
                    #expect(shape?.kind.rawValue == row.top, "\(name)")
                }
            }
        }
    }
}
#endif
