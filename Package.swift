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

// MLX is opt-in for the same reason, and the reason is the same MACRO problem — but unlike
// JavaScriptKit it is gated by a package TRAIT rather than an environment variable.
//
// `Title` is the one model here that does not run through `InferenceSession`: writing a title
// is short autoregressive decode, which measured 5.7-8.3x faster on MLX/GPU than on the ANE,
// and `8e97532` removed MLState when the Core ML path lost. So Title needs mlx-swift-lm.
//
// `MLXHuggingFace` exposes `#huggingFaceLoadModelContainer`, a MACRO — so it pulls swift-syntax
// and host macro plugins exactly as JavaScriptKit does, and a package dependency cannot carry a
// platform condition. Declaring its target edges unconditionally would make every Linux and
// Android consumer clone and build it for a target MLX cannot run on at all, and would risk the
// same static-stdlib link conflict recorded above.
//
// So: the `MLX` trait (SE-0450). SwiftPM PRUNES the mlx-swift-lm and swift-transformers
// package dependencies whenever no enabled trait references them, so a consumer without the
// trait never clones them — the same graph the old `DAL_MLX_BUILD` env var produced, but
// declared in the consumer's manifest instead of ambient process environment (which Xcode's
// resolver could only see via `launchctl setenv`).
//
// The trait is deliberately NOT a default trait: default traits are enabled implicitly by
// every consumer, including the Linux/Android/wasm pipelines, which would then need
// `--disable-default-traits` plumbed through every build (including plugin invocations that
// may not forward trait flags). Opt-in keeps every non-Apple graph exactly as before.
//
// A consumer opts in with:  .package(url: ..., traits: ["MLX"])   (tools-version 6.1+)
// and a build that forgets it fails compiling against the `Title` stub (its MLX API is behind
// `#if MLX`) rather than mis-building.
//
// The env var check stays temporarily as a migration guard: a build still exporting
// DAL_MLX_BUILD gets a loud error instead of silently building a Title stub.
if ProcessInfo.processInfo.environment["DAL_MLX_BUILD"] != nil {
    // Uncomment-to-taste: fatalError would block builds that harmlessly still export it.
    FileHandle.standardError.write(Data(
        "warning: DAL_MLX_BUILD is obsolete; use the 'MLX' package trait instead.\n".utf8))
}

let mlxDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.3"),
    // swift-transformers is NOT optional here even though no line of Title names it. The
    // `#huggingFaceLoadModelContainer` macro EXPANDS into code referencing `HuggingFace`,
    // `HubClient` and `Tokenizers`, so the dependency is invisible at the call site and shows up
    // only as "cannot find 'HubClient' in scope" inside a macro expansion.
    .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.3"),
]
// `MLX` itself is NOT a product of mlx-swift-lm -- it comes transitively from mlx-swift, which
// is why `import MLX` works without declaring it. Declaring it fails resolution.
let mlxProducts: [Target.Dependency] = [
    .product(name: "Transformers", package: "swift-transformers", condition: .when(traits: ["MLX"])),
    .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
    .product(name: "MLXLLM", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
    .product(name: "MLXHuggingFace", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
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
    var resources: [Resource] = []
    var testDependencies: [Target.Dependency] = []
    var testResources: [Resource] = []
    /// Apple-only models get no Android/Node/wasm products. `Title` is MLX, which has no other
    /// platform, and a product promising an artifact that cannot load is worse than its absence.
    var appleOnly: Bool = false
}

let models: [ModelPackage] = [
    .init(name: "Emo"),
    .init(name: "Clips", dependencies: ["Transcript"]),
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
    .init(
        name: "Uhm",
        dependencies: ["AudioIO", "AudioDSP"]
    ),
    .init(
        name: "Ear",
        dependencies: ["AudioIO", "AudioDSP"],
        testResources: [.copy("Resources/ear_frontend_golden.json")]
    ),
    .init(
        name: "Gist",
        dependencies: [.product(name: "RealModule", package: "swift-numerics")],
        testResources: [
            .copy("Resources/gist-sdk-oracle.json"),
            .copy("Resources/gist-feature-oracle.json"),
        ]
    ),
    // The geometric fitters and snapping replace `simd` (Apple-only) with a
    // portable V2, so their transcendental math comes from swift-numerics.
    .init(
        name: "Shapes",
        dependencies: [.product(name: "RealModule", package: "swift-numerics")]
    ),
] + [
    // Cards are written for a `Clip`, which `Transcript` declares. Declared unconditionally;
    // without the `MLX` trait its MLX dependencies are pruned and the target compiles as a
    // stub (`#if MLX` in Title.swift), so the graph is identical on every platform.
    ModelPackage(name: "Title",
                 dependencies: [.byName(name: "Transcript")] + mlxProducts,
                 appleOnly: true),
]
let modelDependencies: [Target.Dependency] = models.map { .byName(name: $0.name) }

// Align is Apple-only (Core ML, Speech, AVFoundation), so it lives outside the
// `models` list: it gets no Android/Node/Web products and no NativeBindings.
// Like every model here it bundles nothing; its Core ML models and sidecars are
// downloaded on demand via its catalog declaration (Sources/Align/Catalog.swift).
// The targets are declared unconditionally so the resolved graph is identical on
// every platform (check:isolation reads it on Linux); the Apple-framework
// sources gate themselves with `#if canImport(...)`, so a non-Apple build
// compiles only the portable declaration and helpers.
let alignProducts: [Product] = [
    .library(name: "Align", targets: ["Align"]),
]

let alignTargets: [Target] = [
    .target(
        name: "Align",
        dependencies: [.byName(name: "DesertAnt")]
    ),
    .testTarget(
        name: "AlignTests",
        dependencies: ["Align", "TestSupport"],
        resources: [
            .copy("Resources/golden.json"),
            .copy("Resources/calibration_golden.json"),
        ]
    ),
]

// Tongue is a pure model: a 2 MB int8 head plus a frozen normalizer/router
// specification, no inference runtime and no model download — the weights ship
// as target resources. Like Align it lives outside the `models` list (no
// NativeBindings, no Web product, no Node/Android dynamic products); unlike
// every other model its Kotlin and JavaScript SDKs are direct ports of the same
// frozen spec (packages/tongue-kotlin, packages/tongue-node), locked to this
// target by the shared golden vectors in Tests/TongueTests/Resources.
let tongueProducts: [Product] = [
    .library(name: "Tongue", targets: ["Tongue"]),
]

let tongueTargets: [Target] = [
    .target(
        name: "Tongue",
        dependencies: [.byName(name: "DesertAnt")],
        resources: [
            .copy("Resources/tongue_int8.bin"),
            .copy("Resources/tongue_meta.json"),
            // Apple requires a privacy manifest from any SDK that collects data
            // or calls a required-reason API; the usage turnstile does both.
            // `.copy` so the file lands at the bundle root, where Xcode's
            // manifest aggregation looks.
            .copy("Resources/PrivacyInfo.xcprivacy"),
        ]
    ),
    .testTarget(
        name: "TongueTests",
        dependencies: ["Tongue", "TestSupport"],
        resources: [
            .copy("Resources/detection_vectors.json"),
            .copy("Resources/normalize_vectors.json"),
            .copy("Resources/script_vectors.json"),
            .copy("Resources/hashing_vectors.json"),
        ]
    ),
]

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

// `appleOnly` models (Title) have no `Web/` entry point, so they get no wasm product.
let modelWasmProducts: [Product] = noJavaScriptKit ? [] : models.filter { !$0.appleOnly }.map { model in
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

let modelWasmTargets: [Target] = noJavaScriptKit ? [] : models.filter { !$0.appleOnly }.map { model in
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
        exclude: model.appleOnly ? [] : ["Web"],
        resources: model.resources
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
            dependencies: [.byName(name: "DesertAnt"), "Tongue"] + modelDependencies
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


// Voz is Apple-only (Core ML, AVFoundation) and, like Align, gets no
// Android/Node/Web products and no NativeBindings. It bundles nothing: its
// Core ML models are downloaded on demand via Sources/Voz/Catalog.swift. It
// drives Core ML directly rather than going through `InferenceSession`, because
// preallocated buffers, `outputBackings` and a lane-batched decode loop are not
// expressible through a generic run(inputs:outputs:) call, and dropping them
// costs roughly 127x on load and about a third of decode throughput.
let vozProducts: [Product] = [
    .library(name: "Voz", targets: ["Voz"]),
]

let vozTargets: [Target] = [
    .target(
        name: "Voz",
        dependencies: [
            .byName(name: "DesertAnt"),
            .byName(name: "AudioIO"),
        ]
    ),
    .testTarget(
        name: "VozTests",
        dependencies: ["Voz", "DesertAnt", "TestSupport"]
    ),
]

let coreTargets: [Target] =
    libraryTargets + testTargets + modelTargets + modelTestTargets + alignTargets
    + tongueTargets + vozTargets

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
    // SwiftPM refuses to resolve `MLXLLM` (macOS 14) into a macOS 13 package. The floor used
    // to rise only behind `DAL_MLX_BUILD`; `platforms` cannot vary by trait, so with the `MLX`
    // trait the iOS 17 / macOS 14 floor is now unconditional. That costs iOS 16 / macOS 13 for
    // Apple consumers that never enable MLX — accepted deliberately: no known Apple consumer
    // sits below iOS 17, and Linux/Android/wasm ignore Apple floors entirely. If such a
    // consumer appears, this is the line to argue about.
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v16), .visionOS(.v1)],
    products: products + modelProducts + alignProducts + vozProducts,
    traits: [
        .trait(
            name: "MLX",
            description: "MLX-backed generation (the Title model). Apple platforms only; "
                + "pulls mlx-swift-lm and swift-transformers into the graph."
        ),
    ],
    dependencies: jsDependencies + mlxDependencies + [
        .package(url: "https://github.com/apple/swift-numerics", from: "1.0.0"),
    ],
    targets: coreTargets
)
