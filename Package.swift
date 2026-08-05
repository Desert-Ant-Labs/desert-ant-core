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
// DAL_WASM_BUILD=1 (mise `test-wasi`, sdk-build `build-web`). Everyone else
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
    var testResources: [Resource] = []
}

let models: [ModelPackage] = [
    .init(name: "Emo"),
    // The catalog's audio model, so the only one that pulls AudioIO/AudioDSP -
    // both of which come with the DesertAnt umbrella, so it needs no extra
    // dependency either.
    .init(name: "Clear"),
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
        .library(name: "ModelBinding", targets: ["ModelBinding"]),
        .library(name: "Checksum", targets: ["Checksum"]),
        // Cross-platform audio: decode/encode (AudioIO) and STFT/mel/framing
        // DSP (AudioDSP), so audio model SDKs ship no per-platform audio code.
        .library(name: "AudioIO", targets: ["AudioIO"]),
        .library(name: "AudioDSP", targets: ["AudioDSP"]),
        .library(name: "ModelStore", targets: ["ModelStore"]),
        .library(name: "ModelCatalog", targets: ["ModelCatalog"]),
        .library(name: "PlatformSupport", targets: ["PlatformSupport"]),
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

let modelProducts: [Product] = models.map { model in
    .library(name: model.name, targets: [model.name])
} + [
    .library(name: "DesertAntAndroid", type: .dynamic, targets: ["Bindings"]),
    .library(name: "DesertAntNode", type: .dynamic, targets: ["Bindings"]),
] + modelWasmProducts

let modelWasmTargets: [Target] = noJavaScriptKit ? [] : models.map { model in
    .executableTarget(
        name: "\(model.name)Web",
        dependencies: [
            .byName(name: model.name),
            .byName(name: "WasmBindings"),
        ] + jsWasi + jsEventLoop,
        path: "Sources/ModelCatalog/\(model.name)/Web"
    )
}

let modelTargets: [Target] = models.map { model in
    .target(
        name: model.name,
        dependencies: [.byName(name: "DesertAnt")] + model.dependencies,
        path: "Sources/ModelCatalog/\(model.name)",
        exclude: ["Web"]
    )
} + [
    .target(
        name: "Bindings",
        dependencies: [.byName(name: "DesertAnt")] + modelDependencies
    ),
] + modelWasmTargets

let modelTestTargets: [Target] = [
    .target(name: "TestSupport", dependencies: ["DesertAnt"], path: "Tests/TestSupport"),
] + models.map { model in
    .testTarget(
        name: "\(model.name)Tests",
        dependencies: [
            .byName(name: model.name),
            .byName(name: "DesertAnt"),
            .byName(name: "TestSupport"),
        ],
        resources: model.testResources
    )
}

let libraryTargets: [Target] = [
        .target(
            name: "DesertAnt",
            dependencies: [
                "Regex", "JSON", "TextNormalization", "Checksum",
                "PlatformSupport", "Usage",
                "ModelCatalog", "ModelStore", "Inference",
                "AudioIO", "AudioDSP",
                "FFIBuffer", "ModelBinding", "HostBridge",
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
        .target(
            name: "ModelCatalog",
            dependencies: ["ModelStore", "Usage", "PlatformSupport"],
            exclude: models.map(\.name)
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
                .target(name: "FFIBuffer", condition: .when(platforms: [.android])),
                .target(name: "CHostBridge", condition: .when(platforms: [.android])),
            ] + jsWasi + jsEventLoop
        ),
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
            name: "WasmBindings",
            dependencies: ["DesertAnt"] + jsWasi + jsEventLoop
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
