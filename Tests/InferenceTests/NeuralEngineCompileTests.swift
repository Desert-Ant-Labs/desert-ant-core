#if canImport(CoreML)
import Testing
@testable import Inference
import Usage

@Test func compileOptionsApplyToTheM6AndA20ProOnly() {
    for name in ["Apple M6", "Apple M6 Pro", "Apple M6 Max", "Apple A20 Pro GPU"] {
        #expect(NeuralEngineCompile.appliesTo(gpuName: name))
    }
    for name in ["Apple M5", "Apple M3 Ultra", "Apple M1 Ultra", "Apple M60", "Apple A19 Pro GPU", "Apple A20 GPU", nil] {
        #expect(!NeuralEngineCompile.appliesTo(gpuName: name))
    }
}

@Test func fasterNeuralEngineCompileIsOnByDefault() {
    #expect(DesertAnt.fasterNeuralEngineCompile)
}

@Test func compileOptionsKeyIsCoreMLs() {
    #expect(NeuralEngineCompile.key == "e5rtCustomANECompilerOptions")
}
#endif
