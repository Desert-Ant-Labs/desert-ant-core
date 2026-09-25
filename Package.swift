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

// MLX is opt-in for the same macro problem, but gated by a package trait rather than an
// environment variable.
//
// `Title` is the one model here that does not run through `InferenceSession`: writing a title
// is short autoregressive decode, which measured 5.7-8.3x faster on MLX/GPU than on the ANE
// (commit `8e97532` benchmarked the Core ML path). So Title needs mlx-swift-lm.
//
// `MLXHuggingFace` exposes `#huggingFaceLoadModelContainer`, a macro, so it pulls swift-syntax
// and host macro plugins exactly as JavaScriptKit does, and a package dependency cannot carry a
// platform condition. Unconditional target edges would make every Linux and Android consumer
// clone and build it for a target MLX cannot run on, and risk the same static-stdlib link
// conflict recorded above.
//
// So: the `MLX` trait (SE-0450). SwiftPM prunes the mlx-swift-lm and swift-transformers
// package dependencies whenever no enabled trait references them, so a consumer without the
// trait never clones them, and the choice lives in the consumer's manifest rather than in the
// process environment (which Xcode's resolver could only see via `launchctl setenv`).
//
// Not a default trait: default traits are enabled implicitly by every consumer, including the
// Linux/Android/wasm pipelines, which would then need `--disable-default-traits` plumbed
// through every build (including plugin invocations that may not forward trait flags).
//
// A consumer opts in with:  .package(url: ..., traits: ["MLX"])   (tools-version 6.1+)
// and a build that forgets it fails compiling against the `Title` stub (its MLX API is behind
// `#if MLX`) rather than mis-building.
//
// TODO: drop this guard once no build exports DAL_MLX_BUILD. A build that still does gets a
// warning instead of silently building a Title stub.
if ProcessInfo.processInfo.environment["DAL_MLX_BUILD"] != nil {
    // A warning, not fatalError, which would block builds that harmlessly still export it.
    FileHandle.standardError.write(Data(
        "warning: DAL_MLX_BUILD is obsolete; use the 'MLX' package trait instead.\n".utf8))
}

let mlxDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.3"),
    // swift-transformers is required even though no line of Title names it. The
    // `#huggingFaceLoadModelContainer` macro expands into code referencing `HuggingFace`,
    // `HubClient` and `Tokenizers`, so the dependency is invisible at the call site and shows up
    // only as "cannot find 'HubClient' in scope" inside a macro expansion.
    .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.3"),
]
// `MLX` itself is not a product of mlx-swift-lm -- it comes transitively from mlx-swift, which
// is why `import MLX` works without declaring it. Declaring it fails resolution.
let mlxProducts: [Target.Dependency] = [
    .product(name: "Transformers", package: "swift-transformers", condition: .when(traits: ["MLX"])),
    .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
    .product(name: "MLXLLM", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
    .product(name: "MLXHuggingFace", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
]

// Xet is opt-in for the graph reason above, not the macro one: swift-xet is pure Swift with no
// plugin, but it pulls swift-nio, async-http-client and swift-nio-transport-services, and a
// package dependency cannot carry a platform condition. Declared as a default trait it would
// make every Linux, Android and wasm build clone and resolve the NIO stack for a transport only
// Apple platforms ever construct (and Android's static-stdlib link has no appetite for NIO's C
// targets). The product edge below carries both conditions, so even with the trait enabled the
// module is absent from a non-Apple build -- which is exactly what `#if canImport(Xet)` in
// Sources/ModelStore/XetTransport.swift tests.
//
// A consumer opts in with:  .package(url: ..., traits: ["Xet"])
// and gets chunk-deduplicated, parallel CAS downloads of the weights. Without it the store
// keeps the single-stream URLSession path, which is also what the Xet transport falls back to,
// so nothing about a model's files or their verification changes either way.
let xetDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/huggingface/swift-xet.git", from: "0.2.3"),
]
let xetProducts: [Target.Dependency] = [
    .product(name: "Xet", package: "swift-xet",
             condition: .when(platforms: [.iOS, .macOS, .tvOS, .visionOS], traits: ["Xet"])),
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

// The ONNX Runtime C shim lives in its own package. Windows only, because that
// is where the NPU execution providers live: Linux and Android stay on LiteRT,
// and adding a second runtime there would ship two copies of the same
// capability. SwiftPM resolves every declared package whatever the target, so
// `#if os(Windows)` keeps it out of the graph entirely on macOS and Linux
// hosts. That check is the host running the manifest, not the build target,
// so the edges below also keep `.when(platforms: [.windows])` for a Windows
// host building for another platform.
//
// The package links `-lonnxruntime` without saying where to look; the import
// library and DLL are vendored under Vendor/onnxruntime by Tools/dal.sh, and
// the headers in the shim must come from the same release (DAL_ORT_VERSION).
//
// Pinned to a revision because the repo has no tags yet. SwiftPM refuses a
// revision (or branch) dependency under a package that is itself resolved by
// version, so this has to become `from:` a tag before a release ships it.
#if os(Windows)
let onnxDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/Desert-Ant-Labs/COnnxRuntime.git",
             revision: "8bcd6d134e996ef457bd1180407e2fed3061dd82"),
]
let onnxProducts: [Target.Dependency] = [
    .product(name: "COnnxRuntime", package: "COnnxRuntime", condition: .when(platforms: [.windows])),
]
#else
let onnxDependencies: [Package.Dependency] = []
let onnxProducts: [Target.Dependency] = []
#endif

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
    /// Whether this model gets an `Android` dynamic library. `Align` has no `.android` artifact:
    /// the host bridge has no NFC, so the lexical bytes could not match training.
    var androidLibrary: Bool = true
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
        dependencies: ["AudioIO", "AudioDSP"],
        testDependencies: ["AudioIO"]
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
    // Image in, pure-Swift resampling (bit-exact with the Pillow eval pipeline),
    // so it needs nothing beyond the core.
    .init(
        name: "Moderator",
        testResources: [
            .copy("Resources/moderator_golden.json"),
            .copy("Resources/sfw_beach.png"),
        ]
    ),
    .init(
        name: "Align",
        dependencies: ["AudioDSP", .product(name: "RealModule", package: "swift-numerics"), "TextNormalization"],
        testResources: [
            .copy("Resources/golden.json"),
            .copy("Resources/calibration_golden.json"),
        ],
        androidLibrary: false
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

// Tongue is a pure model: a 2 MB int8 head plus a frozen normalizer/router
// specification, no inference runtime and no model download; the weights ship
// as target resources. It lives outside the `models` list (no
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
            // No privacy manifest here: the usage turnstile's is `UsagePrivacy`'s,
            // which Tongue reaches through DesertAnt -> Usage like every model.
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
]
// Dynamic libraries cannot link for wasm32, and these products exist for the
// Android and Node pipelines only. Declaring them in the wasm graph would fail
// a whole-package `swift build --swift-sdk <wasm>`, so they follow the same gate
// as the *Web products.
+ (noJavaScriptKit
    ? [.library(name: "CoreAndroidTests", type: .dynamic, targets: ["CoreAndroidTests"])]
    : [])

// `appleOnly` models (Title) have no `Web/` entry point, so they get no wasm product.
let modelWasmProducts: [Product] = noJavaScriptKit ? [] : models.filter { !$0.appleOnly }.map { model in
    .executable(name: "\(model.name)Web", targets: ["\(model.name)Web"])
}

let modelProducts: [Product] = models.flatMap { model -> [Product] in
    model.appleOnly || !noJavaScriptKit
        ? [.library(name: model.name, targets: [model.name])]
        : [.library(name: model.name, targets: [model.name])]
            + (model.androidLibrary
                ? [.library(name: "\(model.name)Android", type: .dynamic, targets: [model.name])]
                : [])
            + [.library(name: "\(model.name)Node", type: .dynamic, targets: [model.name])]
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
            name: "CBCrypt",
            linkerSettings: [.linkedLibrary("bcrypt", .when(platforms: [.windows]))]
        ),
        // NUL-terminated C string decoding (see the file). Dependency-free so
        // the Android core can link it without Foundation.
        .target(name: "CStrings"),
        .target(
            name: "Inference",
            dependencies: [
                "ModelStore", "Usage", "CStrings",
                .target(name: "CLiteRt", condition: .when(platforms: [.linux, .android, .windows])),
                // Unconditional even though JSHost is empty off wasm: PackageToJS
                // walks target dependencies to collect the BridgeJS skeletons it
                // must generate glue from, and a platform-conditional edge is
                // invisible to that walk, so the module would import "JSHost"
                // functions the JS side was never told to supply.
                "JSHost",
            ] + jsWasi + jsEventLoop + onnxProducts
        ),
        .target(
            name: "Regex",
            dependencies: [
                "CStrings",
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
            // an Apple or Android build on an older toolchain. A non-wasm build
            // therefore gets an empty source
            // file, and nothing off wasm imports this module.
            sources: noJavaScriptKit ? ["Empty.swift"] : ["Host.swift"],
            swiftSettings: noJavaScriptKit ? [] : [.enableExperimentalFeature("Extern")],
            plugins: noJavaScriptKit
                ? [] : [.plugin(name: "BridgeJS", package: "JavaScriptKit")]
        ),
        .target(
            name: "TextNormalization",
            dependencies: [
                "CStrings",
                .target(name: "CHostBridge", condition: .when(platforms: [.android])),
            ] + jsWasi
        ),
        // Transcript vocabulary: words, sentences, clips, and time spans. No
        // dependencies, so every platform splits a transcript identically.
        .target(name: "Transcript"),
        .target(name: "FFIBuffer"),
        .target(name: "NativeBindings", dependencies: ["DesertAnt", "CStrings"]),
        .target(
            name: "PlatformSupport",
            dependencies: [
                "CStrings",
                .target(name: "CHostBridge", condition: .when(platforms: [.android])),
            ] + jsWasi + jsEventLoop
        ),
        .target(
            name: "Usage",
            dependencies: [
                "PlatformSupport", "JSON", "CStrings",
                .target(name: "CHostBridge", condition: .when(platforms: [.android])),
                .target(name: "UsagePrivacy",
                        condition: .when(platforms: [.iOS, .macOS, .macCatalyst, .tvOS, .visionOS, .watchOS])),
            ] + jsWasi
        ),
        // Apple requires a privacy manifest from any SDK that collects data or
        // calls a required-reason API, and the turnstile above does both. Every
        // model links it through DesertAnt. It is its own target, reached only
        // on Apple, because a resource would make SwiftPM generate a Foundation
        // `Bundle.module` accessor for Usage, and Usage keeps Foundation off
        // Android and WASI. `.copy` so the file lands at the bundle root, where
        // Xcode's manifest aggregation looks.
        .target(
            name: "UsagePrivacy",
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")]
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
                "CStrings",
                .target(name: "CBCrypt", condition: .when(platforms: [.windows])),
                .target(name: "CHostBridge", condition: .when(platforms: [.android])),
                "JSHost",  // unconditional: see Inference
            ] + jsWasi + jsEventLoop + xetProducts
        ),
        .target(
            name: "HostBridge",
            dependencies: [
                "FFIBuffer", "CStrings",
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
            dependencies: ["HostBridge", "PlatformSupport", "Regex", "JSON", "TextNormalization", "Usage"]
        ),
]

let testTargets: [Target] = [
        .testTarget(name: "HTTPTests", dependencies: ["PlatformSupport"] + jsWasi + jsTestSupport),
        .testTarget(name: "UsageTests", dependencies: ["Usage"] + jsWasi),
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
            resources: [.copy("Resources/testmodel.tflite"),
                        .copy("Resources/testmodel.onnx")]
        ),
        .testTarget(name: "AudioDSPTests", dependencies: ["AudioDSP"]),
        .testTarget(name: "AudioIOTests", dependencies: ["AudioIO", "TestSupport"]),
        .testTarget(name: "FFIBufferTests", dependencies: ["FFIBuffer"]),
]


// Voz runs on Apple (Core ML), in the browser and Node (VozWeb, wasm), and on
// Windows (ONNX Runtime on DirectML), and gets no Android products and no
// NativeBindings. It bundles nothing: its models are downloaded on demand via
// Sources/Voz/Catalog.swift. It drives each runtime directly rather than going
// through `InferenceSession`, because preallocated buffers, output binding and
// a lane-batched decode loop are not expressible through a generic
// run(inputs:outputs:) call, and dropping them costs roughly 127x on load and
// about a third of decode throughput. Sources/Voz/Engine.swift is the seam.
let vozProducts: [Product] = [
    .library(name: "Voz", targets: ["Voz"]),
] + (noJavaScriptKit ? [] : [.executable(name: "VozWeb", targets: ["VozWeb"])])

// Typed on their own: concatenated inline, these lists sit inside the
// `vozTargets` expression below, and Swift 6.2 (check:swift-floor) gives up
// type-checking the whole thing.
let vozDependencies: [Target.Dependency] = [
    .byName(name: "DesertAnt"),
    .byName(name: "AudioIO"),
] + onnxProducts
// AudioIO for the portable WAV decoder the ONNX end-to-end test reads its
// fixture with; COnnxRuntime so `canImport` can gate that test.
let vozTestDependencies: [Target.Dependency] = [
    "Voz", "DesertAnt", "TestSupport", "AudioIO",
] + onnxProducts

let vozTargets: [Target] = [
    .target(
        name: "Voz",
        dependencies: vozDependencies,
        // The wasm entry point is excluded from the library for the same reason
        // every other model's is: it is an executable target of its own, and a
        // `main.swift` inside a library target turns it into an executable.
        exclude: ["Web"]
    ),
    .testTarget(name: "VozTests", dependencies: vozTestDependencies),
] + (noJavaScriptKit ? [] : [
    .executableTarget(
        name: "VozWeb",
        // No WasmBindings, unlike every other model's web entry. That module's
        // @JS surface is the single-session `dalModelHost` seam, which Voz does
        // not use: linking it would make a consumer supply an import Voz never
        // calls (the generated instantiator asks for it unconditionally) and
        // carry the FFI plumbing in the binary for nothing.
        dependencies: [.byName(name: "Voz")]
            + jsWasi + jsEventLoop,
        path: "Sources/Voz/Web",
        // `Bridge.swift` declares this module's exported JS surface with
        // BridgeJS (`@JS`), so it needs the `Extern` feature the generated glue
        // uses and the plugin that generates it, exactly as `WasmBindings`
        // does. Unconditional because this target only exists when
        // JavaScriptKit is in the graph.
        swiftSettings: [.enableExperimentalFeature("Extern")],
        plugins: [.plugin(name: "BridgeJS", package: "JavaScriptKit")]
    ),
])

let coreTargets: [Target] =
    libraryTargets + testTargets + modelTargets + modelTestTargets
    + tongueTargets + vozTargets

let package = Package(
    name: "DesertAnt",
    // The package floor is the lowest any product supports, not the highest any product
    // needs. Models that need more declare it themselves with `@available` rather than
    // dragging every other model up with them:
    //
    //   Clips  iOS 18 / macOS 15 / tvOS 18 / visionOS 2. `clips.mlmodelc` is a multifunction
    //          package and multifunction is an iOS 18 feature. Read off the compiled artifact:
    //          specificationVersion 9. iOS 17 was measured, not assumed: the graph converts at
    //          spec 8, but two fixed-shape packages cost 562 MB against 284, and one
    //          enumerated-shape package cannot use the Neural Engine and ran ~20x slower
    //          (833 ms/batch at 128 against 40 ms).
    //   Title  iOS 17 / macOS 14, MLX's own floor.
    //
    // The one case where the package floor must move is MLX, because a dependency's platform
    // requirement is a manifest-level constraint that `@available` cannot satisfy: SwiftPM
    // refuses to resolve `MLXLLM` (macOS 14) into a macOS 13 package, and `platforms` cannot
    // vary by trait. So the iOS 17 / macOS 14 floor is unconditional. That costs iOS 16 /
    // macOS 13 for Apple consumers that never enable MLX: no known Apple consumer sits below
    // iOS 17, and Linux/Android/wasm ignore Apple floors entirely.
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v16), .visionOS(.v1)],
    products: products + modelProducts + tongueProducts + vozProducts,
    traits: [
        .trait(
            name: "MLX",
            description: "MLX-backed generation (the Title model). Apple platforms only; "
                + "pulls mlx-swift-lm and swift-transformers into the graph."
        ),
        .trait(
            name: "Xet",
            description: "Download model weights over Hugging Face's Xet protocol. Apple "
                + "platforms only; pulls swift-xet and the NIO stack into the graph."
        ),
    ],
    dependencies: jsDependencies + mlxDependencies + xetDependencies + onnxDependencies + [
        .package(url: "https://github.com/apple/swift-numerics", from: "1.0.0"),
    ],
    targets: coreTargets
)
