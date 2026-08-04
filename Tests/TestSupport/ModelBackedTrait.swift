// Where a model-backed suite runs, as one trait instead of a platform `#if`
// around each test.
//
// A trait is a runtime condition, so the tests still compile and type-check on
// every platform, and a skipped run is *reported* as skipped rather than silently
// vanishing from the count. Applied to a suite it covers every test in it:
//
//     @Suite(.serialized, .modelBacked) struct EmoModelTests { … }

import Testing
import DesertAnt
#if canImport(Darwin)
import Darwin
#endif

/// Whether model-backed tests run here: everywhere except iOS, Android, and wasm.
///
/// iOS and Android are deployment targets rather than development hosts. A test
/// run there downloads the model into its own per-app container, so it is a fresh
/// multi-megabyte fetch that no cache outside the device can serve, and its
/// numerics differ from the host's anyway (Core ML picks a different compute unit,
/// Android runs LiteRT). The same code is exercised on macOS and Linux; what is
/// device-specific about those platforms is covered by their own integration
/// harnesses instead.
///
/// On wasm the model store's filesystem and transport come from the JS host the
/// app installs, which the bare `swift package js test` harness never does - so
/// there is nothing for these tests to run against. `ModelFixture` is itself
/// `#if !os(WASI)` for that reason, and the suites that use it are guarded to
/// match; this flag covers the case anyway, so a suite that only carries the
/// trait still does the right thing.
///
/// tvOS, watchOS, and visionOS deliberately still run these - nothing about them
/// needs excluding until CI actually builds for them.
public let runsModelBackedTests: Bool = {
    #if os(iOS) || os(Android) || os(WASI)
    false
    #else
    true
    #endif
}()

public extension Trait where Self == ConditionTrait {
    /// Tests that download and run a real model. See `runsModelBackedTests` for
    /// which platforms that is, and why.
    static var modelBacked: Self {
        .enabled(if: runsModelBackedTests, "model-backed tests do not run on iOS or Android")
    }
}

/// Whether this host has a usable Neural Engine: Apple silicon, not virtualized.
///
/// Core ML picks a compute unit at load time, and a model can behave differently
/// per unit. Redact's current `.mlmodelc` produces **no** neural spans at all on
/// the CPU and GPU paths while being correct on the Neural Engine (verified by
/// forcing each unit with `DAL_COREML_COMPUTE_UNITS`), so on a machine without one
/// its detections silently disappear. A virtualized macOS host - every CI runner -
/// has no Neural Engine, hence this check.
///
/// This is a workaround for a model-export defect, not a property of the SDK, and
/// it should be deleted once redact is re-exported so every compute unit agrees.
/// Emo's export already does.
public let hasNeuralEngine: Bool = {
    // An explicit override wins: forcing a CPU/GPU configuration is exactly how a
    // developer reproduces the CI failure locally, so honour it here too.
    switch environmentVariable("DAL_COREML_COMPUTE_UNITS") {
    case "cpu", "cpuOnly", "cpuAndGPU": return false
    case "cpuAndNeuralEngine", "all": break
    default: break
    }
    #if arch(arm64) && os(macOS)
    var virtualized: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.hv_vmm_present", &virtualized, &size, nil, 0) == 0 else { return false }
    return virtualized == 0
    #elseif arch(arm64) && (os(iOS) || os(tvOS) || os(visionOS))
    return !isSimulator
    #else
    return false
    #endif
}()

private let isSimulator: Bool = {
    #if targetEnvironment(simulator)
    true
    #else
    false
    #endif
}()

public extension Trait where Self == ConditionTrait {
    /// A test whose expectations only hold where Core ML uses the Neural Engine.
    /// See `hasNeuralEngine`; this is temporary.
    static var needsNeuralEngine: Self {
        .enabled(if: hasNeuralEngine, "redact's Core ML export only detects on the Neural Engine")
    }
}
