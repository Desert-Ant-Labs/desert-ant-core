// ModelResources wraps Foundation's Bundle, which is unavailable on WASI (the
// module compiles empty there), so the suite is Apple/Linux only.
#if !os(WASI)
import Testing
import Foundation
import ModelResources

struct ModelResourcesTests {
    @Test func bundledResourceAccess() throws {
        let resources = BundledResources(Bundle.module)
        #expect(try resources.readString(named: "fixture", extension: "txt") == "hello model\n")
        #expect(try resources.path(named: "fixture", extension: "txt").hasSuffix("fixture.txt"))
        #expect(throws: (any Error).self) { try resources.read(named: "missing", extension: "bin") }

        // Full-filename overloads.
        #expect(try resources.readString("fixture.txt") == "hello model\n")
        #expect(try resources.path("fixture.txt").hasSuffix("fixture.txt"))
        #expect(throws: (any Error).self) { try resources.read("missing.bin") }
    }
}
#endif
