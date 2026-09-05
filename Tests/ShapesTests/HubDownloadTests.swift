#if !os(WASI)
import Testing
import TestSupport
@testable import Shapes

@Suite(.hubIntegration)
struct HubDownloadTests {
    @Test func downloadThenRecognize() async throws {
        try await HubDownloadScenario.run(
            ShapesModel.self,
            make: { Shapes(directory: $0) },
            isDownloaded: { $0.isDownloaded() },
            download: { try await $0.download(progress: $1) }
        ) { shapes, cached in
            let traced = try await shapes.recognize(points: ShapesTests.circle())
            guard case .ellipse = traced else {
                Issue.record("expected an ellipse from a traced circle, got \(String(describing: traced))")
                return
            }
            // The second recognizer reads the same directory with no network.
            let diagonal = try await cached.recognize(points: ShapesTests.diagonal())
            guard case .line = diagonal else {
                Issue.record("expected a line from the cached model, got \(String(describing: diagonal))")
                return
            }
        }
    }
}
#endif
