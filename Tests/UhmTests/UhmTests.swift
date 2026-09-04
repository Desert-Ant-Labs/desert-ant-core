import Testing
@testable import Uhm

struct UhmTests {

    @Test func biasThresholds() {
        #expect(Uhm.Bias.precision.minConfidence == 0.75)
        #expect(Uhm.Bias.balanced.minConfidence == 0.65)
        #expect(Uhm.Bias.recall.minConfidence == 0.50)
    }

    @Test func defaultOptions() {
        let options = Uhm.Options.default
        #expect(options.bias.minConfidence == 0.65)
        #expect(options.includeTypes)
        #expect(options.minConfidence == nil)
        #expect(options.minDurationSec == 0.12)
    }
}
