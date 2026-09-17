#if canImport(CoreML)
import CoreML
import Metal
#endif
#if canImport(Darwin)
import Darwin
#endif
#if canImport(IOKit)
import IOKit
#endif
import Foundation

/// What this machine is, in the terms the placement rules turn on.
///
/// Not a product name and not a chip name: the same product spans silicon that
/// wants opposite answers, and a name is a lookup table that is wrong about
/// every machine released after it was written. These are quantities, and Core
/// ML and Metal report them directly.
///
/// The framework that faces the same problem is ggml/llama.cpp, which reads
/// `supportsFamily` for capability gates, `recommendedMaxWorkingSetSize` for
/// budget, and - where nothing else answers - the Metal device's name, with an
/// environment override over the top. The same shape is used here: a measured
/// quantity where one exists, a class where it does not, and `DAL_*` overrides
/// over everything.
public struct Hardware: Sendable {

    /// Neural Engine cores, straight from Core ML.
    ///
    /// The number that matters is how many engines there are, and this is how
    /// that shows: every Apple chip carries a 16-core engine, and the Ultra
    /// parts, which are two dies fused, report 32. Measured on the machines
    /// here - M1 16, M5 16, A18 Pro 16, M3 Ultra 32.
    public let neuralEngineCores: Int

    /// Performance cores. What decides whether a stage that overlaps another
    /// can have a core to itself.
    public let performanceCores: Int

    /// GPU cores where the machine will say, and an estimate from the chip
    /// class where it will not - which is iOS, where the registry entry that
    /// carries it is not readable. See ``estimatedGPUCores``.
    public let gpuCores: Int

    /// Whether the GPU is a phone's: an A-series part, which is the narrowest
    /// Apple ships and is also drawing the screen off a battery. An M-series
    /// iPad answers false, because it is a desktop GPU in a tablet.
    public let isPhoneClass: Bool

    /// The newest Metal feature family the GPU supports, as a generation
    /// number: 7 for M1 and A14, 8 for M2 and A15/A16, 9 for M3 and later.
    /// Zero when Metal is unavailable.
    public let gpuGeneration: Int

    /// Whether there is a Neural Engine at all. False on Intel Macs, and in
    /// the simulator, where the host's hardware is not the guest's.
    public var hasNeuralEngine: Bool { neuralEngineCores > 0 }

    /// Engines, not cores: what a submission can be spread across.
    public var neuralEngines: Int { max(1, neuralEngineCores / 16) }

    public static let current = Hardware()

    private init() {
        #if targetEnvironment(simulator)
        // The simulator runs the host's silicon through a translation layer
        // and reports neither honestly, so claim nothing and let every rule
        // take its conservative branch.
        neuralEngineCores = 0
        performanceCores = 0
        gpuCores = 0
        isPhoneClass = false
        gpuGeneration = 0
        #else
        performanceCores = Self.sysctlInt("hw.perflevel0.physicalcpu") ?? 0

        var cores = 0
        var name = ""
        var generation = 0
        #if canImport(CoreML)
        if #available(macOS 14.0, iOS 17.0, tvOS 17.0, visionOS 1.0, *) {
            for device in MLComputeDevice.allComputeDevices {
                switch device {
                case .neuralEngine(let engine): cores = engine.totalCoreCount
                case .gpu(let gpu): name = gpu.metalDevice.name
                default: break
                }
            }
        }
        if name.isEmpty { name = MTLCreateSystemDefaultDevice()?.name ?? "" }
        if let metal = MTLCreateSystemDefaultDevice() {
            if metal.supportsFamily(.apple9) { generation = 9 }
            else if metal.supportsFamily(.apple8) { generation = 8 }
            else if metal.supportsFamily(.apple7) { generation = 7 }
        }
        #endif
        neuralEngineCores = cores
        gpuGeneration = generation
        // "Apple M3 Ultra", "Apple A18 Pro GPU": the letter after Apple is the
        // line, and it is the one thing no quantity reports. Anything that is
        // not an M is treated as a phone, including an unreadable name, which
        // is the branch that never takes the GPU.
        let phone = !name.hasPrefix("Apple M")
        isPhoneClass = phone
        gpuCores = Self.gpuCoreCount() ?? Self.estimatedGPUCores(phoneClass: phone,
                                                                 generation: generation)
        #endif
    }

    /// GPU cores for a machine that will not report them, which is every iOS
    /// device: the registry entry that carries the count is not readable
    /// there, and Metal describes what a GPU can do rather than how wide it is.
    ///
    /// The estimate is the narrowest part that fits what is known, so a rule
    /// with a width threshold fails towards the Neural Engine rather than
    /// towards a GPU that turns out to be small. A-series parts ship 4 to 6
    /// cores; an M-series part has never shipped fewer than 8, and none from
    /// the M2 generation on has shipped fewer than 10.
    static func estimatedGPUCores(phoneClass: Bool, generation: Int) -> Int {
        if phoneClass { return 5 }
        return generation >= 8 ? 10 : 8
    }

    private static func sysctlInt(_ name: String) -> Int? {
        #if canImport(Darwin)
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
        #else
        return nil
        #endif
    }

    /// The accelerator's own registry entry, which macOS exposes and iOS does
    /// not. `nil` means "ask the estimate".
    private static func gpuCoreCount() -> Int? {
        #if canImport(IOKit) && os(macOS)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AGXAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var cores = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let value = IORegistryEntryCreateCFProperty(
                service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int {
                cores = max(cores, value)
            }
        }
        return cores > 0 ? cores : nil
        #else
        return nil
        #endif
    }
}
