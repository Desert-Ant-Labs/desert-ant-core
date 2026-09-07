#if !os(WASI)
import Testing
@testable import ModelStore

struct ModelRuntimeTests {
    @Test func aDistributionWithoutAlternateFilesRunsThePlatformDefault() {
        let d = ModelDistribution(repo: "r", revision: "v1", files: [.current: ["m.mlmodelc/"]])
        #expect(d.currentRuntime == .platformDefault)
        #expect(d.currentFiles == ["m.mlmodelc/"])
        #expect(!d.hasFallback)
        #expect(d.platformDefault == d)
    }

    @Test func alternateFilesArePreferredOnlyWhereTheRuntimeIsCurrent() async {
        let d = ModelDistribution(repo: "r", revision: "v1", files: [.current: ["m.mlmodelc/"]],
                                  runtimeFiles: [.coreAI: ["m.aimodel/"]])
        if ModelRuntime.current == .coreAI {
            #expect(d.currentRuntime == .coreAI)
            #expect(d.currentFiles == ["m.aimodel/"])
            #expect(d.hasFallback)
            #expect(d.platformDefault.currentFiles == ["m.mlmodelc/"])
            #expect(!d.platformDefault.hasFallback)
        } else {
            #expect(d.currentRuntime == .platformDefault)
            #expect(d.currentFiles == ["m.mlmodelc/"])
            #expect(!d.hasFallback)
        }
        let pinned = await d.resolving(.exact("v2"))
        #expect(pinned.revision == "v2")
        #expect(pinned.runtimeFiles == d.runtimeFiles)
    }

    @Test func theRuntimeFollowsTheArtifactExtension() {
        #expect(ModelRuntime.inferred(fromPath: "/cache/clear-studio.aimodel") == .coreAI)
        #expect(ModelRuntime.inferred(fromPath: "clear-studio.mlmodelc") == .coreML)
        #expect(ModelRuntime.inferred(fromPath: "clear-studio.tflite") == .liteRT)
        #expect(ModelRuntime.inferred(fromPath: "weights.bin") == nil)
    }
}
#endif
