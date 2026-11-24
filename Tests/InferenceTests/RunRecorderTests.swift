import Testing
@testable import Inference

struct GraphPlacementTests {
    // LiteRtHwAccelerators bits, as the shim reports them.
    private let cpu: Int32 = 1, gpu: Int32 = 2, gpuOrCpu: Int32 = 3

    private func resolve(compiled: Int32, registered: Int32 = -1, nonCpu: Int32 = -1,
                         fallback: Int32 = 0) -> (ProcessorSet, GraphPlacement.Fallback?) {
        let resolved = GraphPlacement.resolve(requested: gpuOrCpu, compiled: compiled, registered: registered,
                                              nonCpuFullyAccelerated: nonCpu, fallback: fallback)
        return (resolved.processors, resolved.fallback)
    }

    @Test func aCpuCompileRunsOnTheCpu() {
        #expect(resolve(compiled: cpu) == ([.cpu], nil))
    }

    @Test func aWholeGraphOnTheGpuRunsThereAlone() {
        #expect(resolve(compiled: gpuOrCpu, registered: gpuOrCpu, nonCpu: 1) == ([.gpu], nil))
    }

    @Test func aSplitGraphRunsOnBoth() {
        #expect(resolve(compiled: gpuOrCpu, registered: gpuOrCpu, nonCpu: 0) == ([.gpu, .cpu], nil))
    }

    /// LiteRT compiles GPU|CPU without complaint when the accelerator library never loaded.
    @Test func aGpuWithNoAcceleratorRunsOnTheCpu() {
        #expect(resolve(compiled: gpuOrCpu, registered: cpu, nonCpu: 0) == ([.cpu], .acceleratorMissing))
    }

    @Test func aFallbackRunsOnTheCpuForItsReason() {
        #expect(resolve(compiled: cpu, fallback: 1) == ([.cpu], .virtualDevice))
        #expect(resolve(compiled: cpu, fallback: 2) == ([.cpu], .compileFailed))
        #expect(resolve(compiled: cpu, fallback: 3) == ([.cpu], .buffersUnavailable))
    }

    /// Off Android the runtime is not asked, and a GPU|CPU compile proves nothing.
    @Test func unknownFactsLeaveThePlacementUnknown() {
        #expect(resolve(compiled: gpuOrCpu) == ([], nil))
    }

    @Test func graphsAreNamedByTheirFileAlone() {
        #expect(GraphPlacement.graphName(modelPath: "/data/user/0/app/cache/toxic/toxic.tflite", modelBytes: nil) == "toxic.tflite")
        #expect(GraphPlacement.graphName(modelPath: #"C:\Users\me\cache\toxic.tflite"#, modelBytes: nil) == "toxic.tflite")
        #expect(GraphPlacement.graphName(modelPath: "", modelBytes: [1, 2, 3]) == "in-memory model (3 bytes)")
    }

    @Test func unknownBitsAreIgnored() {
        #expect(resolve(compiled: 8 | cpu) == ([.cpu], nil))
    }
}

// Wasm builds leave out RunRecorder: only native hosts record runs.
#if !os(WASI)
struct RunRecorderTests {
    private func placement(_ graph: String) -> GraphPlacement {
        GraphPlacement(graph: graph, requested: [.gpu, .cpu], processors: [.gpu], fallback: nil)
    }

    @Test func recordsEachGraphOnceInFirstRunOrder() {
        let recorder = RunRecorder()
        for graph in ["mel", "encoder", "decode", "decode", "encoder", "decode"] {
            recorder.record(placement(graph))
        }
        #expect(recorder.recorded.map(\.graph) == ["mel", "encoder", "decode"])
    }

    /// One name, two placements: the fallback must not hide behind the other.
    @Test func aSharedNameKeepsDifferentPlacements() {
        let recorder = RunRecorder()
        recorder.record(placement("model.tflite"))
        recorder.record(GraphPlacement(graph: "model.tflite", requested: [.gpu, .cpu], processors: [.cpu],
                                       fallback: .compileFailed))
        recorder.record(placement("model.tflite"))
        #expect(recorder.recorded.map(\.processors) == [[.gpu], [.cpu]])
    }

    @Test func concurrentRunsOfOneCallShareItsRecorder() async {
        let recorder = RunRecorder()
        await InferenceContext.$runRecorder.withValue(recorder) {
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<64 {
                    group.addTask { InferenceContext.runRecorder?.record(placement("graph\(index % 8)")) }
                }
            }
        }
        #expect(Set(recorder.recorded.map(\.graph)) == Set((0..<8).map { "graph\($0)" }))
        #expect(recorder.recorded.count == 8)
    }

    @Test func nothingIsRecordedOutsideACall() {
        #expect(InferenceContext.runRecorder == nil)
    }
}
#endif
