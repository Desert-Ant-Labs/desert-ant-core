#if !os(WASI)
import Foundation
import Testing

public extension Trait where Self == ConditionTrait {
    /// Tests that are too slow (or too resource-hungry) for every commit: they
    /// run when a job opts in, the same shape as `.hubIntegration`. The normal
    /// CI matrix never sets the variable; a scheduled or manual lane does.
    static var longRunning: Self {
        .enabled(
            if: ProcessInfo.processInfo.environment["DAL_LONG_TESTS"] == "1",
            "set DAL_LONG_TESTS=1 to run long-running tests")
    }
}
#endif
