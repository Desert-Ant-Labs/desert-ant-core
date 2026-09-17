import Testing
@testable import Inference

// The ranking rule, checked without a machine: probing is what varies per
// device, but which measurement wins must not.

private let candidates: [(name: String, units: ComputeUnits)] = [
    ("all", .all), ("gpu", .cpuAndGPU), ("ane", .cpuAndNeuralEngine),
]

@Test func anUnmeasuredIncumbentKeepsThePlacement() {
    #expect(Placement.select(candidates: candidates, measured: [:]).name == "all")
    // A challenger alone is not evidence: without the incumbent's own cost
    // there is nothing to compare it against.
    #expect(Placement.select(candidates: candidates, measured: ["gpu": 0.001]).name == "all")
}

@Test func theIncumbentKeepsTiesAndNarrowWins() {
    // Clear on an M1: the GPU loses outright and must not be adopted.
    #expect(Placement.select(candidates: candidates,
                             measured: ["all": 0.0179, "gpu": 0.0279]).name == "all")
    // Inside the margin, samples come from different runs and a few percent is
    // drift rather than a difference.
    #expect(Placement.select(candidates: candidates,
                             measured: ["all": 1.0, "gpu": 0.97]).name == "all")
    #expect(Placement.select(candidates: candidates,
                             measured: ["all": 1.0, "gpu": 0.90]).name == "gpu")
}

@Test func theFastestChallengerWinsRatherThanTheFirstListed() {
    // Uhm on an M3 Ultra: both challengers clear the margin, and the choice has
    // to be the faster of them rather than whichever the caller wrote first.
    let chosen = Placement.select(candidates: candidates,
                                  measured: ["all": 0.0938, "gpu": 0.0443, "ane": 0.0700])
    #expect(chosen.name == "gpu")
    #expect(chosen.units == .cpuAndGPU)
}

@Test func nonsenseMeasurementsAreIgnoredRatherThanRanked() {
    // A cache that has been hand-edited, or a run timed across a sleep.
    #expect(Placement.select(candidates: candidates,
                             measured: ["all": 1.0, "gpu": 0, "ane": .infinity]).name == "all")
    #expect(Placement.select(candidates: candidates, measured: ["all": .nan]).name == "all")
}

@Test func oneCandidateIsNotADecision() {
    // A phone pins the engine; `next` must not read a file to confirm it.
    let pinned: [(name: String, units: ComputeUnits)] = [("ane", .cpuAndNeuralEngine)]
    #expect(Placement.next(model: "/nonexistent", candidates: pinned).name == "ane")
    #expect(!Placement.measures(candidates: pinned))
    #expect(Placement.measures(candidates: candidates))
}
