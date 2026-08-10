import XCTest
@testable import Uhm

final class UhmTests: XCTestCase {

    func testBiasThresholds() {
        XCTAssertEqual(Uhm.Bias.precision.minConfidence, 0.75)
        XCTAssertEqual(Uhm.Bias.balanced.minConfidence, 0.65)
        XCTAssertEqual(Uhm.Bias.recall.minConfidence, 0.50)
    }

    func testDefaultOptions() {
        let options = Uhm.Options.default
        XCTAssertEqual(options.bias.minConfidence, 0.65)
        XCTAssertTrue(options.includeTypes)
        XCTAssertNil(options.minConfidence)
        XCTAssertEqual(options.minDurationSec, 0.12)
    }
}
