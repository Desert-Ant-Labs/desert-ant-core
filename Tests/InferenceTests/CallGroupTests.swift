import Testing
@testable import Inference

struct CallGroupTests {
    @available(*, deprecated)
    @Test func aRetiredCallGroupRunsItsBodyAndBindsNothing() async throws {
        #expect(await InferenceContext.withCallGroup { 7 } == 7)
        let bound = await InferenceContext.withCallGroup(id: "group-1") { InferenceContext.callGroup }
        #expect(bound == nil)
        InferenceContext.endCallGroup("group-1")
        await #expect(throws: CancellationError.self) {
            try await InferenceContext.withCallGroup { throw CancellationError() }
        }
        _ = InferenceCallGroup()
    }
}
