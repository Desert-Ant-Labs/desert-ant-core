// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Shared package for Desert Ant Labs' on-device model SDKs.
//
// JavaScriptKit pulls macros that conflict with Android's static-stdlib link.
// Android builds therefore omit it; wasm-only sources are already conditional.

let noJavaScriptKit = ProcessInfo.processInfo.environment["SWIFT_ANDROID_STATIC_BUILD"] != nil

// DAL_INFERENCE_LITERT selects LiteRT instead of ONNX Runtime on native hosts.
let liteRT = ProcessInfo.processInfo.environment["DAL_INFERENCE_LITERT"] != nil
let inferenceRuntimeDeps: [Target.Dependency] = liteRT
    ? [.target(name: "CLiteRt", condition: .when(platforms: [.linux, .android, .macOS]))]
    : [.target(name: "COnnxRuntime", condition: .when(platforms: [.linux, .android]))]
let inferenceSwiftSettings: [SwiftSetting] = liteRT ? [.define("DAL_LITERT")] : []

// Avoid linking the default test run against an unavailable native runtime.
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
                "FFIBuffer", "ModelBinding", "HostBridge",
            ]
        ),
        // Consumers provide the selected native inference library.
        .systemLibrary(name: "COnnxRuntime"),
        .target(
            name: "CLiteRt",
            linkerSettings: [.linkedLibrary("LiteRt")]
        ),
        .target(
            name: "Inference",
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
        .target(
            name: "ModelCatalog",
            dependencies: ["ModelStore", "Usage", "PlatformSupport"],
            exclude: models.map(\.name)
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
