import Testing
@testable import Inference

// The placement rules read the machine, so what can be checked here is that
// they read it consistently and that the answers are the ones the sweeps found.
// The numbers those came from are in `Placement` and `BatchSize`.

#if canImport(Darwin)

@Test func theMachineDescribesItselfCoherently() {
    let machine = Hardware.current
    #if targetEnvironment(simulator)
    // The simulator reports the host's silicon through a translation layer, so
    // it must claim nothing rather than claim the Mac it is running on.
    #expect(!machine.hasNeuralEngine)
    #expect(machine.gpuCores == 0)
    #else
    #expect(machine.performanceCores > 0, "every Apple chip has performance cores")
    #if arch(arm64)
    #expect(machine.hasNeuralEngine)
    // Core ML reports 16 cores per engine, so anything else is a signal this
    // code has misread - a 24-core part would quietly become one engine.
    #expect(machine.neuralEngineCores % 16 == 0,
            "an engine is 16 cores; \(machine.neuralEngineCores) is not a whole number of them")
    #expect(machine.neuralEngines == machine.neuralEngineCores / 16)
    // An Ultra is the only part with two engines, and it is also the only one
    // with a second die's worth of performance cores.
    #expect((machine.neuralEngines >= 2) == (machine.performanceCores >= 16))
    #expect(machine.gpuGeneration >= 7, "Apple silicon is at least Metal family apple7")
    #expect(machine.gpuCores > 0, "width is read where possible and estimated where not")
    #endif
    #endif
}

@Test func everyPlacementIsRunnableOnThisMachine() {
    // Whatever the rules answer here, it must be something this machine can
    // actually load: a device with no engine must never be handed one.
    let machine = Hardware.current
    let rules = [Placement.gpuFriendly, Placement.neuralEngineFriendly, Placement.overlappedStage]
    for placement in rules {
        if !machine.hasNeuralEngine {
            #expect(placement == .all, "without an engine there is nothing to choose")
        } else {
            #expect(placement != .all, "an engine machine should not fall back to Core ML's guess")
        }
    }
}

@Test func theGPUWidthEstimateFailsTowardsTheEngine() {
    // Where the width cannot be read it is estimated, and the estimate must
    // never be generous: a phone must land below every threshold, and an
    // M1-generation part must land below the one that separates it from an M5.
    #expect(Hardware.estimatedGPUCores(phoneClass: true, generation: 9) < 8)
    #expect(Hardware.estimatedGPUCores(phoneClass: false, generation: 7) == 8)
    #expect(Hardware.estimatedGPUCores(phoneClass: false, generation: 8) == 10)
}

@Test func aPhoneKeepsItsEngineAndItsScreen() {
    // The GPU rules are written so that phone-class silicon never takes the
    // GPU: it is the narrowest Apple ships and it is drawing the screen.
    let machine = Hardware.current
    guard machine.isPhoneClass else { return }
    #expect(Placement.gpuFriendly == .cpuAndNeuralEngine)
    #expect(Placement.neuralEngineFriendly == .cpuAndNeuralEngine)
    // Two performance cores, and something else to do with them.
    #expect(Placement.overlappedStage == .cpuAndNeuralEngine)
}

@Test func theBlockWidthFollowsTheEngineCount() {
    // One submission per window can only reach one engine; a machine with two
    // needs a block to reach the second. Everything else stays where it was.
    let engines = Hardware.current.neuralEngines
    let width = BatchSize.forOverlappedEncoder
    #expect(width == (engines >= 2 ? min(engines * 4, BatchSize.maximum) : 1))
    // The staging cost is what the ceiling protects, so nothing may exceed it
    // however many engines a future part reports.
    #expect(width <= BatchSize.maximum,
            "a caller stages `maximum` slots and must not be asked for more")
    #expect(width >= 1)
}

#endif
