// swift-tools-version: 6.2
import PackageDescription
import Foundation

// Shared package for Desert Ant Labs' on-device model SDKs.
//
// The wasm backends need JavaScriptKit, which pulls swift-syntax (macros). A
// package dependency cannot carry a platform condition -- only the *product*
// dependencies below can -- so declaring it unconditionally makes every consumer
// (iOS, macOS, Linux, Android) clone JavaScriptKit + swift-syntax and build the
// host macro plugins, for code that is entirely `#if os(WASI)`. It also breaks
// Android's static-stdlib link, where host macros conflict with `-resource-dir`.
//
// So JavaScriptKit is opt-in: only a build that actually targets wasm sets
// DAL_WASM_BUILD=1, which is `mise run test:wasi` and `mise run build:wasm`.
// A wasm task that forgets it fails with "no product named
// 'EmoWeb'", because the *Web products below are declared with it. Everyone else
// resolves a graph without it. SWIFT_ANDROID_STATIC_BUILD stays honoured as a
// hard opt-out so an Android build can never pick it up by accident.
//
// `Package.resolved` differs between the two modes (SwiftPM prunes unused pins),
// which is why it stays gitignored -- switching modes just re-resolves.

let wasmBuild = ProcessInfo.processInfo.environment["DAL_WASM_BUILD"] != nil
let noJavaScriptKit = !wasmBuild
    || ProcessInfo.processInfo.environment["SWIFT_ANDROID_STATIC_BUILD"] != nil

// MLX is opt-in for the same reason, and the reason is the same MACRO problem.
//
// `Title` is the one model here that does not run through `InferenceSession`: writing a title
// is short autoregressive decode, which measured 5.7-8.3x faster on MLX/GPU than on the ANE,
// and `8e97532` removed MLState when the Core ML path lost. So Title needs mlx-swift-lm.
//
// `MLXHuggingFace` exposes `#huggingFaceLoadModelContainer`, a MACRO — so it pulls swift-syntax
// and host macro plugins exactly as JavaScriptKit does, and a package dependency cannot carry a
// platform condition. Declaring it unconditionally would make every Linux and Android consumer
// clone and build it for a target MLX cannot run on at all, and would risk the same
// static-stdlib link conflict recorded above.
//
// So: `DAL_MLX_BUILD=1` to get Title. Everyone else resolves a graph without it, and a build
// that forgets the flag fails with "no product named 'Title'" rather than mis-building.
//
// This is a conservative default rather than a settled one. If Linux and Android CI show
// mlx-swift-lm resolves harmlessly, invert it — Apple is the majority consumer and Title
// should arrive by default for them. Check before flipping; do not assume.
let mlxBuild = ProcessInfo.processInfo.environment["DAL_MLX_BUILD"] != nil
    && ProcessInfo.processInfo.environment["SWIFT_ANDROID_STATIC_BUILD"] == nil

// `AutoEdit` selects clips from a transcript. Transcribing the recording and
// cutting it down to the selected spans both happen outside this SDK; this
// switch scopes the video pipeline to consumers that opt into it.
let videoBuild = ProcessInfo.processInfo.environment["DAL_VIDEO_BUILD"] != nil
    && ProcessInfo.processInfo.environment["SWIFT_ANDROID_STATIC_BUILD"] == nil

let mlxDependencies: [Package.Dependency] = !mlxBuild ? [] : [
    .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.3"),
    // swift-transformers is NOT optional here even though no line of Title names it. The
    // `#huggingFaceLoadModelContainer` macro EXPANDS into code referencing `HuggingFace`,
    // `HubClient` and `Tokenizers`, so the dependency is invisible at the call site and shows up
    // only as "cannot find 'HubClient' in scope" inside a macro expansion.
    .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.3"),
]
// `MLX` itself is NOT a product of mlx-swift-lm -- it comes transitively from mlx-swift, which
// is why `import MLX` works without declaring it. Declaring it fails resolution.
let mlxProducts: [Target.Dependency] = !mlxBuild ? [] : [
    .product(name: "Transformers", package: "swift-transformers"),
    .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
    .product(name: "MLXLLM", package: "mlx-swift-lm"),
    .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
]

let jsDependencies: [Package.Dependency] = noJavaScriptKit ? [] : [
    .package(url: "https://github.com/swiftwasm/JavaScriptKit", from: "0.56.1"),
]
let jsWasi: [Target.Dependency] = noJavaScriptKit ? [] : [
    .product(name: "JavaScriptKit", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
]
let jsEventLoop: [Target.Dependency] = noJavaScriptKit ? [] : [
    .product(name: "JavaScriptEventLoop", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
]
let jsTestSupport: [Target.Dependency] = noJavaScriptKit ? [] : [
    .product(name: "JavaScriptEventLoopTestSupport", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
]

// This is the only SwiftPM model list. Target-specific differences live here.
struct ModelPackage {
    let name: String
    var dependencies: [Target.Dependency] = []
    var testDependencies: [Target.Dependency] = []
    var testResources: [Resource] = []
    /// Apple-only models get no Android/Node/wasm products. `Title` is MLX, which has no other
    /// platform, and a product promising an artifact that cannot load is worse than its absence.
    var appleOnly: Bool = false
}

let models: [ModelPackage] = [
    .init(name: "Emo"),
    .init(
        name: "Clips",
        dependencies: ["Transcript"],
        testResources: [
            .copy("Resources/clip_vocab_subset.bin"),
            .copy("Resources/tokenizer_parity.json"),
            .copy("Resources/clips-multifunction.mlmodelc"),
        ]
    ),
    .init(
        name: "Clear",
        dependencies: ["AudioIO", "AudioDSP"],
        testDependencies: ["AudioIO"]
    ),
    .init(
        name: "Redact",
        dependencies: [.product(name: "RealModule", package: "swift-numerics")],
        testResources: [.copy("Resources/deterministic_corpus.json")]
    ),
] + (mlxBuild ? [
    // Cards are written for a `Clip`, which `Transcript` declares.
    ModelPackage(name: "Title",
                 dependencies: [.byName(name: "Transcript")] + mlxProducts,
                 appleOnly: true),
] : [])
let modelDependencies: [Target.Dependency] = models.map { .byName(name: $0.name) }

// Keep arrays typed separately to avoid manifest type-checker timeouts.
let products: [Product] = [
        .library(name: "DesertAnt", targets: ["DesertAnt"]),
        .library(name: "Regex", targets: ["Regex"]),
        .library(name: "JSON", targets: ["JSON"]),
        .library(name: "TextNormalization", targets: ["TextNormalization"]),
        // Shared by every model and pipeline that reads a transcript.
        .library(name: "Transcript", targets: ["Transcript"]),
        .library(name: "FFIBuffer", targets: ["FFIBuffer"]),
        // Cross-platform audio: decode/encode (AudioIO) and STFT/mel/framing
        // DSP (AudioDSP), so audio model SDKs ship no per-platform audio code.
        .library(name: "AudioIO", targets: ["AudioIO"]),
        .library(name: "AudioDSP", targets: ["AudioDSP"]),
        .library(name: "ModelStore", targets: ["ModelStore"]),
        .library(name: "ModelCatalog", targets: ["ModelCatalog"]),
        .library(name: "PlatformSupport", targets: ["PlatformSupport"]),
        .library(name: "JSHost", targets: ["JSHost"]),
        .library(name: "Usage", targets: ["Usage"]),
        .library(name: "Inference", targets: ["Inference"]),
        .library(name: "HostBridge", targets: ["HostBridge"]),
        .library(name: "CHostBridge", targets: ["CHostBridge"]),
        .library(name: "WasmBindings", targets: ["WasmBindings"]),
        .library(name: "CoreAndroidTests", type: .dynamic, targets: ["CoreAndroidTests"]),
]

let modelWasmProducts: [Product] = noJavaScriptKit ? [] : models.map { model in
    .executable(name: "\(model.name)Web", targets: ["\(model.name)Web"])
}

let modelProducts: [Product] = models.flatMap { model in
    model.appleOnly
        ? [.library(name: model.name, targets: [model.name])]
        : [
            .library(name: model.name, targets: [model.name]),
            .library(name: "\(model.name)Android", type: .dynamic, targets: [model.name]),
            .library(name: "\(model.name)Node", type: .dynamic, targets: [model.name]),
        ]
} + modelWasmProducts

let modelWasmTargets: [Target] = noJavaScriptKit ? [] : models.map { model in
    .executableTarget(
        name: "\(model.name)Web",
        dependencies: [
            .byName(name: model.name),
            .byName(name: "WasmBindings"),
        ] + jsWasi + jsEventLoop,
        path: "Sources/\(model.name)/Web"
    )
}

let modelTargets: [Target] = models.map { model in
    .target(
        name: model.name,
        dependencies: [.byName(name: "DesertAnt"), .byName(name: "NativeBindings")]
            + model.dependencies,
        path: "Sources/\(model.name)",
        // Only models with a wasm entry point have a `Web/` directory to exclude. An exclude
        // naming a path that does not exist is a warning today and could become an error.
        exclude: model.appleOnly ? [] : ["Web"]
    )
} + modelWasmTargets

let modelTestTargets: [Target] = [
    .target(name: "TestSupport", dependencies: ["DesertAnt"], path: "Tests/TestSupport"),
] + models.map { model in
    .testTarget(
        name: "\(model.name)Tests",
        dependencies: [
            .byName(name: model.name),
            .byName(name: "DesertAnt"),
            .byName(name: "TestSupport"),
        ] + model.testDependencies,
        resources: model.testResources
    )
}

let libraryTargets: [Target] = [
        .target(
            name: "DesertAnt",
            dependencies: [
                "Regex", "JSON", "TextNormalization",
                "PlatformSupport", "Usage",
                "ModelCatalog", "ModelStore", "Inference",
                "FFIBuffer", "HostBridge",
            ]
        ),
        .target(
            name: "CLiteRt",
            linkerSettings: [.linkedLibrary("LiteRt")]
        ),
        .target(
            name: "Inference",
            dependencies: [
                "ModelStore", "Usage",
                .target(name: "CLiteRt", condition: .when(platforms: [.linux, .android])),
                // Unconditional even though JSHost is empty off wasm: PackageToJS
                // walks target dependencies to collect the BridgeJS skeletons it
                // must generate glue from, and a platform-conditional edge is
                // invisible to that walk, so the module would import "JSHost"
                // functions the JS side was never told to supply.
                "JSHost",
            ] + jsWasi + jsEventLoop
        ),
        .target(
            name: "Regex",
            dependencies: [
                .target(name: "CHostBridge", condition: .when(platforms: [.android])),
            ] + jsWasi
        ),
        .target(
            name: "JSON",
            dependencies: [
                .target(name: "CHostBridge", condition: .when(platforms: [.android])),
            ] + jsWasi
        ),
        .target(name: "CHostBridge"),
        // The typed contract with the JavaScript host on wasm (see the file).
        // BridgeJS generates the call glue and the TypeScript type the JS side
        // must satisfy, so both settings are wasm-only exactly as for
        // WasmBindings.
        .target(
            name: "JSHost",
            dependencies: jsWasi,
            exclude: noJavaScriptKit
                ? ["bridge-js.config.json", "Host.swift"]
                : ["bridge-js.config.json", "Empty.swift"],
            // `Host.swift` is body-less `@JSFunction`/`@JSGetter` declarations,
            // which only parse where the BridgeJS macros exist. Swift parses
            // inactive `#if` branches for syntax, so `#if os(WASI)` does not save
            // an Apple or Android build on an older toolchain (this package
            // supports 5.9+). A non-wasm build therefore gets an empty source
            // file, and nothing off wasm imports this module.
            sources: noJavaScriptKit ? ["Empty.swift"] : ["Host.swift"],
            swiftSettings: noJavaScriptKit ? [] : [.enableExperimentalFeature("Extern")],
            plugins: noJavaScriptKit
                ? [] : [.plugin(name: "BridgeJS", package: "JavaScriptKit")]
        ),
        .target(
            name: "TextNormalization",
            dependencies: [
                .target(name: "CHostBridge", condition: .when(platforms: [.android])),
            ] + jsWasi
        ),
        // Transcript vocabulary: words, sentences, clips, and time spans. No
        // dependencies, so every platform splits a transcript identically.
        .target(name: "Transcript"),
        .target(name: "FFIBuffer"),
        .target(name: "NativeBindings", dependencies: ["DesertAnt"]),
        .target(
            name: "PlatformSupport",
            dependencies: [
                .target(name: "CHostBridge", condition: .when(platforms: [.android])),
            ] + jsWasi + jsEventLoop
        ),
        .target(
            name: "Usage",
            dependencies: [
                "PlatformSupport", "JSON",
                .target(name: "CHostBridge", condition: .when(platforms: [.android])),
            ] + jsWasi
        ),
        // Everything a model declares (its catalog entry), how it is loaded, and
        // what it implements to be reachable from another language.
        .target(
            name: "ModelCatalog",
            dependencies: ["ModelStore", "Usage", "PlatformSupport", "FFIBuffer"]
        ),
        // Pure-Swift DSP (STFT/ISTFT, windows, mel, framing, vector ops);
        // Accelerate-backed on Apple via canImport, so no explicit dependency.
        .target(name: "AudioDSP"),
        // Audio decode/encode: AVFoundation on Apple, the host decoder via
        // CHostBridge on Android, the JS host on wasm, the pure-Swift WAV
        // codec on Linux/other. FFIBuffer's FFIReader parses the host buffer.
        .target(
            name: "AudioIO",
            dependencies: [
                // FFIBuffer is only *used* on Android (HostAudioIO parses the
                // host's buffer), but the dependency is unconditional: Xcode
                // drops a target from a link entirely if any edge to it is
                // platform-conditional, which loses libFFIBuffer for every
                // other target that needs it on iOS.
                "FFIBuffer",
                .target(name: "CHostBridge", condition: .when(platforms: [.android])),
            ] + jsWasi + jsEventLoop
        ),
        .target(
            name: "ModelStore",
            dependencies: [
                .target(name: "CHostBridge", condition: .when(platforms: [.android])),
                "JSHost",  // unconditional: see Inference
            ] + jsWasi + jsEventLoop
        ),
        .target(
            name: "HostBridge",
            dependencies: [
                "FFIBuffer",
                .target(name: "CHostBridge", condition: .when(platforms: [.android])),
            ]
        ),
        // `Exports.swift` declares the module's exported JS surface with
        // BridgeJS (`@JS`), which needs the `Extern` feature (the generated glue
        // uses `@_extern(wasm)`) and the plugin that generates that glue plus the
        // `.d.ts` every model package ships. Both are wasm-only: the target's
        // sources are `#if os(WASI)`, and a build without JavaScriptKit has no
        // plugin to apply.
        .target(
            name: "WasmBindings",
            dependencies: ["DesertAnt"] + jsWasi + jsEventLoop,
            swiftSettings: noJavaScriptKit ? [] : [.enableExperimentalFeature("Extern")],
            plugins: noJavaScriptKit
                ? [] : [.plugin(name: "BridgeJS", package: "JavaScriptKit")]
        ),
        .target(
            name: "CoreAndroidTests",
            dependencies: ["HostBridge", "Regex", "JSON", "TextNormalization"]
        ),
]

let testTargets: [Target] = [
        .testTarget(name: "HTTPTests", dependencies: ["PlatformSupport"] + jsTestSupport),
        .testTarget(name: "UsageTests", dependencies: ["Usage"]),
        .testTarget(name: "InferenceUsageTests", dependencies: ["Inference", "Usage"]),
        .testTarget(name: "PlatformSupportTests", dependencies: ["PlatformSupport"] + jsTestSupport),
        .testTarget(name: "ModelStoreTests", dependencies: ["ModelStore"]),
        .testTarget(
            name: "BindingsTests",
            dependencies: [.byName(name: "DesertAnt"), .byName(name: "TestSupport")]
                + modelDependencies
        ),
        .testTarget(
            name: "ModelCatalogTests",
            dependencies: [.byName(name: "DesertAnt")] + modelDependencies
        ),
        .testTarget(name: "TextNormalizationTests", dependencies: ["TextNormalization"]),
        .testTarget(name: "TranscriptTests", dependencies: ["Transcript"]),
        .testTarget(name: "RegexTests", dependencies: ["Regex"]),
        .testTarget(name: "JSONTests", dependencies: ["JSON"]),
        .testTarget(
            name: "InferenceTests",
            dependencies: ["Inference"],
            resources: [.copy("Resources/testmodel.tflite")]
        ),
        .testTarget(name: "AudioDSPTests", dependencies: ["AudioDSP"]),
        .testTarget(name: "AudioIOTests", dependencies: ["AudioIO"]),
        .testTarget(name: "FFIBufferTests", dependencies: ["FFIBuffer"]),
]

// The video pipeline: transcribe, select, cut.
let autoEditTargets: [Target] = !videoBuild ? [] : [
    .target(
        name: "AutoEdit",
        dependencies: [
            "Clips", "DesertAnt", "Transcript",
        ]
    ),
]
let autoEditProducts: [Product] = !videoBuild ? [] : [
    .library(name: "AutoEdit", targets: ["AutoEdit"]),
]

let coreTargets: [Target] =
    libraryTargets + testTargets + modelTargets + modelTestTargets + autoEditTargets

let package = Package(
    name: "DesertAnt",
    // The package floor is the LOWEST any product supports, not the highest any product
    // needs. Emo, Clear and Redact run on iOS 16 and keep it.
    //
    // Clips and Title need more, and they declare it THEMSELVES with `@available` rather than
    // dragging every other model up with them:
    //
    //   Clips  iOS 18 / macOS 15 / tvOS 18 / visionOS 2. `clips.mlmodelc` is a MULTIFUNCTION
    //          package and multifunction is an iOS 18 feature. Read off the compiled artifact:
    //          specificationVersion 9. iOS 17 was measured, not assumed: the graph converts at
    //          spec 8, but two fixed-shape packages cost 562 MB against 284, and one
    //          enumerated-shape package cannot use the Neural Engine and ran ~20x slower
    //          (833 ms/batch at 128 against 40 ms).
    //   Title  iOS 17 / macOS 14, MLX's own floor.
    //
    // An earlier version of this branch raised the whole package to iOS 17, then to iOS 18, on
    // the reasoning that "SwiftPM platform floors are package-wide". That is true of THIS
    // declaration and false of the thing that matters: `@available` is per-declaration, so a
    // model that needs a newer OS can say so without costing the models that do not.
    //
    // The one case where the package floor genuinely must move is MLX, because a DEPENDENCY's
    // platform requirement is a manifest-level constraint that `@available` cannot satisfy:
    // SwiftPM refuses to resolve `MLXLLM` (macOS 14) into a macOS 13 package. So the floor
    // rises only when the MLX dependency is actually pulled in, which is the same
    // `DAL_MLX_BUILD` switch that pulls it.
    platforms: mlxBuild
        ? [.iOS(.v17), .macOS(.v14), .tvOS(.v16), .visionOS(.v1)]
        : [.iOS(.v16), .macOS(.v13), .tvOS(.v16), .visionOS(.v1)],
    products: products + modelProducts + autoEditProducts,
    dependencies: jsDependencies + mlxDependencies + [
        .package(url: "https://github.com/apple/swift-numerics", from: "1.0.0"),
    ],
    targets: coreTargets
)
