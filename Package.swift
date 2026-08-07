// swift-tools-version: 5.9
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
}

let models: [ModelPackage] = [
    .init(name: "Emo"),
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
]
let modelDependencies: [Target.Dependency] = models.map { .byName(name: $0.name) }

// Keep arrays typed separately to avoid manifest type-checker timeouts.
let products: [Product] = [
        .library(name: "DesertAnt", targets: ["DesertAnt"]),
        .library(name: "Regex", targets: ["Regex"]),
        .library(name: "JSON", targets: ["JSON"]),
        .library(name: "TextNormalization", targets: ["TextNormalization"]),
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
    [
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
        exclude: ["Web"]
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
            exclude: ["bridge-js.config.json"],
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
