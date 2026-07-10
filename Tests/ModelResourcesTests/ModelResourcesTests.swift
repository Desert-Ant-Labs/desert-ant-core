import XCTest
import ModelResources

final class ModelResourcesTests: XCTestCase {
    func testBundledResourceAccess() throws {
        let resources = BundledResources(Bundle.module)
        XCTAssertEqual(try resources.readString(named: "fixture", extension: "txt"), "hello model\n")
        XCTAssertTrue(try resources.path(named: "fixture", extension: "txt").hasSuffix("fixture.txt"))
        XCTAssertThrowsError(try resources.read(named: "missing", extension: "bin"))

        // Full-filename overloads.
        XCTAssertEqual(try resources.readString("fixture.txt"), "hello model\n")
        XCTAssertTrue(try resources.path("fixture.txt").hasSuffix("fixture.txt"))
        XCTAssertThrowsError(try resources.read("missing.bin"))
    }
}
