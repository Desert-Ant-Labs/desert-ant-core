import Foundation

/// Which processor a model runs on, decided from what the machine is.
///
/// `.all` is not a shortcut to the best device, it is Core ML guessing, and it
/// guesses badly often enough to matter: over ten minutes of speech on an M3
/// Ultra, Uhm's detector runs at 529 RTFx at `.all` and 1115 pinned to the GPU.
/// Nor is the answer a property of the model alone - the same detector gains
/// 3.0x from the GPU on an Ultra and 1.2x on an M5 - or of the product, since
/// two Macs of one family can want opposite placements.
///
/// It is, however, a property of the silicon, and the silicon says what it is.
/// Core ML reports the Neural Engine's core count, Metal reports the GPU's
/// family and name, and the kernel reports the CPU's topology. Those are the
/// terms the answers turn on, they cost nothing to read, and they are right on
/// the first call of a fresh install - which is the whole point, because the
/// alternatives are not.
///
/// Two of them were built and thrown away before this:
///
/// - Learning from real transcriptions. Correct, and it bills the user: the
///   first runs on a machine pay for the answer in proportion to their length,
///   so a first two-hour recording funds the exploration.
/// - Probing at load on synthetic input. Cheaper, and still 16 s on an M1 by
///   the time it could separate the choices that were close, which is 16 s of
///   staring at a spinner for a 4% decision.
///
/// The cost of reading the machine instead is that a chip nobody has measured
/// gets an answer by extrapolation rather than by test. The thresholds below
/// are therefore written to fall back to the conservative branch - the Neural
/// Engine, which is never catastrophic on any model here - whenever a fact
/// cannot be read or falls outside what has been seen.
public enum Placement {

    /// Where a model whose graph the Neural Engine handles badly should run.
    ///
    /// Uhm's detector is that kind of graph: the engine is its worst device on
    /// every machine measured, by 4.6x on an M3 Ultra (243 RTFx against 1115),
    /// and `.all` does not rescue it because Core ML picks the engine too. Any
    /// GPU that is not also drawing a phone's screen beats it:
    ///
    ///                 GPU    .all   engine
    ///   M1 (8 cores)  132     108       94
    ///   M5 (10)       369     256      296
    ///   M3 Ultra (60) 1115    529      243
    ///   iPhone 16 Pro 154     167      180
    ///
    /// The phone is the exception and the reason the test is on GPU width
    /// rather than on platform: its six cores are the narrowest GPU Apple
    /// ships, and they have a screen to draw.
    public static var gpuFriendly: ComputeUnits {
        let machine = Hardware.current
        guard machine.hasNeuralEngine else { return .all }
        // No width threshold: the engine loses to every GPU that is not a
        // phone's, including an M1's, which is the narrowest there is.
        return machine.isPhoneClass ? .cpuAndNeuralEngine : .cpuAndGPU
    }

    /// Where a model the Neural Engine is good at should run.
    ///
    /// Clear is that kind: its enhancement is convolutional and the engine is
    /// competitive everywhere, so the GPU only wins once it is wide enough to
    /// out-run the engine outright. The measured boundary sits between the two
    /// narrowest desktop GPUs:
    ///
    ///                  GPU   engine   .all
    ///   M1 (8 cores)   171      250    251
    ///   M5 (10)        453      412    397
    ///   M3 Ultra (60)  520      245    354
    ///   iPhone 16 Pro   60      350    347
    ///
    /// Ten is a measured boundary, not a derived one: an M1 loses a third on
    /// its GPU and an M5 gains a tenth, and no machine between them has been
    /// tried. A chip whose GPU is narrower than an M5's therefore keeps the
    /// engine, which is the branch that is never bad.
    public static var neuralEngineFriendly: ComputeUnits {
        let machine = Hardware.current
        guard machine.hasNeuralEngine else { return .all }
        return !machine.isPhoneClass && machine.gpuCores >= wideGPUCores
            ? .cpuAndGPU : .cpuAndNeuralEngine
    }

    /// The width at which a GPU starts beating the engine on a graph the
    /// engine is good at. Measured on both sides and nowhere in between, so it
    /// is the least certain number here: an M1's eight cores lose a third, an
    /// M5's ten gain a tenth.
    private static let wideGPUCores = 10

    /// Where a small, dispatch-bound stage that runs *beside* engine work
    /// should go.
    ///
    /// This is not the same question as the two above, because the stage does
    /// not have the machine to itself. Voz's decode overlaps its encoder, so on
    /// the engine it queues behind it and on the CPU it runs alongside, and
    /// what decides the winner is whether there is a performance core spare to
    /// run it on:
    ///
    ///                     CPU   engine
    ///   M1 (4 P-cores)    254      243
    ///   M5 (4)            445      405
    ///   M3 Ultra (20)     498      244
    ///   iPhone 16 Pro (2) 280      309
    ///
    /// A phone has two performance cores and something else to do with them.
    /// Every Mac and every M-series iPad has at least four.
    public static var overlappedStage: ComputeUnits {
        let machine = Hardware.current
        guard machine.hasNeuralEngine else { return .all }
        return machine.performanceCores >= 4 ? .cpuOnly : .cpuAndNeuralEngine
    }
}
