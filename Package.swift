// swift-tools-version: 5.9
import PackageDescription
import Foundation

// DesertAnt: reusable, cross-platform Swift building blocks shared by Desert Ant
// Labs' on-device model SDKs. Each module has one public API and a per-platform
// backend behind it (Apple/Linux use the OS SDK; Android and wasm call the host
// through CHostBridge), so consumers write no platform code.
//
// An SDK depends on the `DesertAnt` umbrella product and writes one import; the
// modules below stay individually importable for the core's own targets, tests,
// and consumers that want a narrower dependency.
//
//   DesertAnt    re-exports everything below (`import DesertAnt`)
//   ModelCatalog every model in the monorepo: coordinates + per-platform files
//   Regex        stdlib-`Regex`-shaped matching, type `Pattern`
//                (NSRegularExpression | java.util.regex | JS RegExp)
//   JSON         Codable decoding (Foundation.JSONDecoder | host JSON tree | JS JSON.parse)
//   TextNormalization  String.nfkc via the platform normalizer
//                (Foundation | Android java.text.Normalizer | JS String.normalize)
//   ModelStore   verified Hub downloads + platform-neutral StoredModel access
//   ModelResources  SwiftPM bundle resource loading
//   PlatformSupport environment + synchronous FFI/async bridge + HTTP client
//   Usage        usage turnstile: builds/sends `load` events over the HTTP client
//   FFIBuffer    length-prefixed typed C-ABI buffer (no hand-rolled JSON)
//   CHostBridge  generic host-callback bridge a runtime shim installs on Android
//   HostBridge   Android JNI harness: byte marshalling + installs CHostBridge
//                callbacks against a host class (pairs with kotlin/HostBridge.kt)
//
// The wasm backends need JavaScriptKit, which pulls swift-syntax macros that
// conflict with Android's static-stdlib link (`-resource-dir`). Setting
// SWIFT_ANDROID_STATIC_BUILD drops JavaScriptKit from the manifest so an Android
// build has no macros in its graph. The wasm backend files are `#if os(WASI)`,
// so omitting the dependency is harmless off-wasm.

let noJavaScriptKit = ProcessInfo.processInfo.environment["SWIFT_ANDROID_STATIC_BUILD"] != nil

// Select the Android/Linux inference backend at build time. Default is ONNX
// Runtime (COnnxRuntime + ORTSession). Set DAL_INFERENCE_LITERT to use LiteRT
// (CLiteRt + LiteRTSession) instead: the consumer then vendors libLiteRt.so
// (and passes -lLiteRt -L...) and ships .tflite artifacts, the same way the ORT
// path vendors libonnxruntime.so and ships .onnx. Apple always uses Core ML and
// wasm always uses the JS host session, so this only affects Android/Linux.
let liteRT = ProcessInfo.processInfo.environment["DAL_INFERENCE_LITERT"] != nil

// The on-device runtime target Inference links on Android/Linux, and the Swift
// flag that switches ORTSession vs LiteRTSession in the session factory.
// LiteRT can also back a native server-side build on Apple hosts (the Node
// SDK's darwin native uses it so it consumes the same .tflite as Linux), so its
// target is available on macOS too when the LiteRT backend is selected. The
// default Apple SDK build leaves DAL_INFERENCE_LITERT unset and uses Core ML.
let inferenceRuntimeDeps: [Target.Dependency] = liteRT
    ? [.target(name: "CLiteRt", condition: .when(platforms: [.linux, .android, .macOS]))]
    : [.target(name: "COnnxRuntime", condition: .when(platforms: [.linux, .android]))]
let inferenceSwiftSettings: [SwiftSetting] = liteRT ? [.define("DAL_LITERT")] : []

// The LiteRT backend test suite is only added when that backend is selected, so
// the default (ORT) `swift test` does not link Inference and need libonnxruntime.
let liteRTTests: [Target] = liteRT ? [
    .testTarget(
        name: "InferenceTests",
        dependencies: ["Inference"],
        resources: [.copy("Resources/testmodel.tflite")],
        swiftSettings: inferenceSwiftSettings
    ),
] : []

let jsDependencies: [Package.Dependency] = noJavaScriptKit ? [] : [
    .package(url: "https://github.com/swiftwasm/JavaScriptKit", from: "0.56.1"),
]
let jsWasi: [Target.Dependency] = noJavaScriptKit ? [] : [
    .product(name: "JavaScriptKit", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
]
// JavaScriptEventLoop provides `try await JSPromise.value` for the wasm ModelStore.
let jsEventLoop: [Target.Dependency] = noJavaScriptKit ? [] : [
    .product(name: "JavaScriptEventLoop", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
]
// Installs the JS-backed global executor so `async` tests run under the wasm
// test harness (needed by any suite that awaits, e.g. the fetch-backed HTTP).
let jsTestSupport: [Target.Dependency] = noJavaScriptKit ? [] : [
    .product(name: "JavaScriptEventLoopTestSupport", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
]

// Extracted into explicitly-typed constants so the Swift manifest type-checker
// handles each array on its own. Inlined into one big Package(...) literal, the
// many conditional array concatenations (inferenceRuntimeDeps/jsWasi/jsEventLoop
// + liteRTTests) blow past the type-checker's time budget on some toolchains
// (e.g. Xcode 26.x): "unable to type-check this expression in reasonable time".
let products: [Product] = [
        // The umbrella a model SDK depends on: re-exports every module below, so
        // an SDK writes `import DesertAnt` and one product dependency. The
        // individual products stay published for granular consumers.
        .library(name: "DesertAnt", targets: ["DesertAnt"]),
        .library(name: "Regex", targets: ["Regex"]),
        .library(name: "JSON", targets: ["JSON"]),
        .library(name: "TextNormalization", targets: ["TextNormalization"]),
        .library(name: "FFIBuffer", targets: ["FFIBuffer"]),
        // What a model implements to be reachable from another language.
        .library(name: "ModelBinding", targets: ["ModelBinding"]),
        .library(name: "Checksum", targets: ["Checksum"]),
        .library(name: "ModelStore", targets: ["ModelStore"]),
        // Registry of every model SDK in this monorepo (id + published coordinates).
        .library(name: "ModelCatalog", targets: ["ModelCatalog"]),
        .library(name: "PlatformSupport", targets: ["PlatformSupport"]),
        // Usage turnstile: builds/sends `load` events over PlatformSupport's HTTP client.
        .library(name: "Usage", targets: ["Usage"]),
        .library(name: "ModelResources", targets: ["ModelResources"]),
        // Named-tensor inference sessions: Core ML | ONNX Runtime | JS host.
        .library(name: "Inference", targets: ["Inference"]),
        // Android JNI harness for model SDKs (empty off-Android).
        .library(name: "HostBridge", targets: ["HostBridge"]),
        // Exposed so an Android runtime's JNI shim can install the callbacks.
        .library(name: "CHostBridge", targets: ["CHostBridge"]),
        // Android on-device integration harness, cross-compiled to a JNI .so and
        // driven by the instrumented test in androidtest/ (empty off-Android).
        .library(name: "CoreAndroidTests", type: .dynamic, targets: ["CoreAndroidTests"]),
]

// The wasm entry points, dropped from an Android build along with JavaScriptKit.
let modelWasmProducts: [Product] = noJavaScriptKit ? [] : [
        .executable(name: "EmoWeb", targets: ["EmoWeb"]),
        .executable(name: "RedactWeb", targets: ["RedactWeb"]),
]

// The model SDKs. Each lives in one folder under Sources/ModelCatalog (its
// declaration, pipeline, and cross-language entry points), and is its own module
// so two models can both have a `Model` or `Tokenizer` type. `swift-numerics` is
// the only non-core dependency any of them needs so far (redact's softmax).
let modelProducts: [Product] = [
        .library(name: "Emo", targets: ["Emo"]),
        .library(name: "Redact", targets: ["Redact"]),
        // One native library for the whole SDK: the model is a `modelId`
        // argument to the generic `dal_*` C ABI, so a new model needs no new
        // symbol, library, or host-side plumbing. Off Android only the C ABI half
        // compiles (the JNI file is `#if os(Android)`), which is what koffi binds
        // for the server-side Node build.
        .library(name: "DesertAntAndroid", type: .dynamic, targets: ["Bindings"]),
        .library(name: "DesertAntNode", type: .dynamic, targets: ["Bindings"]),
] + modelWasmProducts

let modelWasmTargets: [Target] = noJavaScriptKit ? [] : [
        .executableTarget(
            name: "EmoWeb",
            dependencies: ["Emo"] + jsWasi + jsEventLoop,
            // The wasm hosts bridge JavaScriptKit's non-Sendable JS values across
            // the event-loop executor; this package's 5.9 tools version means
            // language mode 5, so those crossings stay warnings.
            path: "Sources/ModelCatalog/Emo/Web"
        ),
        .executableTarget(
            name: "RedactWeb",
            dependencies: ["Redact"] + jsWasi + jsEventLoop,
            path: "Sources/ModelCatalog/Redact/Web"
        ),
]

let modelTargets: [Target] = [
        .target(
            name: "Emo",
            dependencies: ["DesertAnt"],
            path: "Sources/ModelCatalog/Emo",
            exclude: ["Web"]
        ),
        .target(
            name: "Redact",
            dependencies: [
                "DesertAnt",
                // Portable `Double.exp` for the softmax (the stdlib has no
                // transcendentals; this avoids a per-platform libm import).
                .product(name: "RealModule", package: "swift-numerics"),
            ],
            path: "Sources/ModelCatalog/Redact",
            exclude: ["Web"]
        ),
        // The shared cross-language layer: the `dal_*` C ABI, the JNI entry
        // points, and the registry naming every model. It depends on the models
        // (the ABI must be able to construct them), while a model depends only on
        // the `ModelBinding` protocols in the core.
        .target(name: "Bindings", dependencies: ["DesertAnt", "Emo", "Redact"]),
] + modelWasmTargets

let modelTestTargets: [Target] = [
        // Shared by every model's suite: the memoized model download and the
        // `.modelBacked` trait that decides where those tests run. A plain target
        // under Tests/, so it is not a product - test-only code stays out of the
        // published surface.
        .target(name: "TestSupport", dependencies: ["DesertAnt"], path: "Tests/TestSupport"),
        // The suites download the pinned model once instead of loading a
        // committed copy; no model artifact is in the repo.
        .testTarget(name: "EmoTests", dependencies: ["Emo", "DesertAnt", "TestSupport"]),
        .testTarget(
            name: "RedactTests",
            dependencies: ["Redact", "DesertAnt", "TestSupport"],
            resources: [.copy("Resources/deterministic_corpus.json")]
        ),
]

let libraryTargets: [Target] = [
        .target(
            name: "DesertAnt",
            dependencies: [
                "Regex", "JSON", "TextNormalization", "Checksum",
                "PlatformSupport", "Usage",
                "ModelCatalog", "ModelStore", "ModelResources", "Inference",
                "FFIBuffer", "ModelBinding", "HostBridge",
            ]
        ),
        // ONNX Runtime C API (Android/Linux). Vendored header; binaries that
        // use Inference on these platforms link libonnxruntime.so themselves
        // (the SDKs vendor it per platform). Compiling needs no library, so
        // core builds and tests run without it.
        .systemLibrary(name: "COnnxRuntime"),
        // LiteRT (formerly TensorFlow Lite) C API shim (Android/Linux),
        // selected instead of COnnxRuntime when DAL_INFERENCE_LITERT is set.
        // Vendored LiteRT C headers + a small C shim over libLiteRt.so; the
        // consumer links libLiteRt.so (the SDKs vendor it per platform). Only
        // built when the LiteRT backend is enabled.
        .target(
            name: "CLiteRt",
            linkerSettings: [.linkedLibrary("LiteRt")]
        ),
        .target(
            name: "Inference",
            // Depends on Usage so every session the factory builds records usage;
            // the concrete backends are non-public, so there is no untracked path.
            dependencies: [
                "ModelStore", "Usage",
            ] + inferenceRuntimeDeps + jsWasi + jsEventLoop,
            swiftSettings: inferenceSwiftSettings
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
        .target(
            name: "TextNormalization",
            dependencies: [
                .target(name: "CHostBridge", condition: .when(platforms: [.android])),
            ] + jsWasi
        ),
        .target(name: "FFIBuffer"),
        .target(name: "ModelBinding", dependencies: ["FFIBuffer"]),
        .target(name: "Checksum"),
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
        .target(name: "ModelResources"),
        // The catalog's shared half: the ModelDeclaration protocol every model
        // conforms to. Each model folder beside it is its own target (see
        // modelTargets), so it is excluded here.
        .target(name: "ModelCatalog", dependencies: ["ModelStore"], exclude: ["Emo", "Redact"]),
        .target(
            name: "ModelStore",
            dependencies: [
                "Checksum",
                .target(name: "CHostBridge", condition: .when(platforms: [.android])),
            ] + jsWasi + jsEventLoop
        ),
        .target(
            name: "HostBridge",
            dependencies: [
                "FFIBuffer",
                .target(name: "CHostBridge", condition: .when(platforms: [.android])),
            ]
        ),
        .target(
            name: "CoreAndroidTests",
            dependencies: ["HostBridge", "Regex", "JSON", "TextNormalization"]
        ),
]

let testTargets: [Target] = [
        .testTarget(name: "ChecksumTests", dependencies: ["Checksum"]),
        .testTarget(name: "HTTPTests", dependencies: ["PlatformSupport"] + jsTestSupport),
        .testTarget(name: "UsageTests", dependencies: ["Usage"]),
        .testTarget(name: "InferenceUsageTests", dependencies: ["Inference", "Usage"]),
        .testTarget(name: "PlatformSupportTests", dependencies: ["PlatformSupport"] + jsTestSupport),
        .testTarget(name: "ModelStoreTests", dependencies: ["ModelStore"]),
        // Cross-model invariants, so it owns the registry of every model (the
        // shared half cannot name the models that depend on it).
        .testTarget(name: "ModelCatalogTests", dependencies: ["DesertAnt", "Emo", "Redact"]),
        .testTarget(
            name: "ModelResourcesTests",
            dependencies: ["ModelResources"],
            resources: [.copy("Resources/fixture.txt")]
        ),
        .testTarget(name: "TextNormalizationTests", dependencies: ["TextNormalization"]),
        .testTarget(name: "RegexTests", dependencies: ["Regex"]),
        .testTarget(name: "JSONTests", dependencies: ["JSON"]),
] + liteRTTests

let coreTargets: [Target] = libraryTargets + testTargets + modelTargets + modelTestTargets

let package = Package(
    name: "DesertAnt",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .visionOS(.v1),
    ],
    products: products + modelProducts,
    dependencies: jsDependencies + [
        .package(url: "https://github.com/apple/swift-numerics", from: "1.0.0"),
    ],
    targets: coreTargets
)
