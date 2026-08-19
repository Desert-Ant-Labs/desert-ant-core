#if !os(WASI)
import XCTest
import TestSupport
@testable import Shapes

final class HubDownloadTests: XCTestCase {
    func testDownloadThenRecognize() async throws {
        try await HubDownloadScenario.run(
            ShapesModel.self,
            make: { Shapes(directory: $0) },
            isDownloaded: { $0.isDownloaded() },
            download: { try await $0.download(progress: $1) }
        ) { shapes, cached in
            guard case .ellipse = try await shapes.recognize(points: ShapesTests.circle()) else {
                return XCTFail("expected an ellipse from a traced circle")
            }
            // The second recognizer reads the same directory with no network.
            guard case .line = try await cached.recognize(points: ShapesTests.diagonal()) else {
                return XCTFail("expected a line from the cached model")
            }
        }
    }
}
#endif
