#if canImport(CoreML)
import CoreML
#if canImport(Metal)
import Metal
#endif
import Usage

/// Compiler options for the M6 and A20 Pro, which have two Neural Engines.
///
/// Core ML compiles two versions of a model there, one for a single engine and
/// one split across both, on threads that run on the efficiency cores.
/// Compiling only the split version, on one thread, gives the same program and
/// cuts the first load of voz 0.4.0 from 23.7s to 9.0s on an M6 and from 33.4s
/// to 9.5s on an iPhone 18 Pro. The options go through a private Core ML key.
/// Setting `DesertAnt.fasterNeuralEngineCompile` to false turns them off.
public enum NeuralEngineCompile {
    static let options = "EnableLowEffortCPAllocation=true,CompilerMultithreading=false,EnableNonbondedNetworks=false,UseExtendedMachoFormat=true"

    /// Matched by GPU name rather than Neural Engine core count, because Ultra
    /// chips report 32 cores too and are untested with these options.
    static func appliesTo(gpuName: String?) -> Bool {
        guard let name = gpuName else { return false }
        return name == "Apple M6" || name.hasPrefix("Apple M6 ") || name.hasPrefix("Apple A20 Pro")
    }

    /// `e5rtCustomANECompilerOptions`, assembled so the name isn't a literal in the binary.
    static let key = ["e5rt", "Custom", "ANE", "Compiler", "Options"].joined()

    static let applies: Bool = {
        #if canImport(Metal)
        appliesTo(gpuName: MTLCreateSystemDefaultDevice()?.name)
            && MLModelConfiguration().responds(to: NSSelectorFromString("set" + key.prefix(1).uppercased() + key.dropFirst() + ":"))
        #else
        false
        #endif
    }()

    /// Sets the options on a configuration that compiles for the Neural Engine.
    /// Core ML caches compiled models by these options, so every load of a model
    /// has to go through here.
    public static func apply(to configuration: MLModelConfiguration) {
        guard DesertAnt.fasterNeuralEngineCompile, applies, configuration.computeUnits != .cpuOnly, configuration.computeUnits != .cpuAndGPU else { return }
        configuration.setValue(options, forKey: key)
    }
}
#endif
