// swift-tools-version: 6.1
import PackageDescription
import Foundation

// __PRODUCT__: on-device __DESCRIPTION_SHORT__ for every platform.
//
//   desert-ant-core              reusable primitives (JSON, ModelStore,
//                                TextNormalization, Inference sessions + factory)
//   Sources/__PRODUCT__                  shared pipeline (pure Swift; platform variation
//                                is data: artifact names, no tensor branching)
//   Sources/__PRODUCT__CoreMLResources   Apple/Core ML model files (not LiteRT)
//   Sources/__PRODUCT__TFLiteResources   LiteRT (.tflite) model files for Linux/Windows
//   Sources/__PRODUCT__Android           C ABI + Swift JNI -> packages/__MODEL__-kotlin (+ Node native)
//   Sources/__PRODUCT__Web               wasm entry point -> packages/__MODEL__-node

// The Android static-stdlib link needs no macros in the build graph, so this
// flag (set by `mise run android-natives`) drops JavaScriptKit and the wasm entry
// point. The wasm/JS code is all `#if os(WASI)`, so it is absent off-wasm anyway.
let noJavaScriptKit = ProcessInfo.processInfo.environment["SWIFT_ANDROID_STATIC_BUILD"] != nil

let jsDependencies: [Package.Dependency] = noJavaScriptKit ? [] : [
    .package(url: "https://github.com/swiftwasm/JavaScriptKit", from: "0.56.1"),
]
let packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "__CORE_VERSION__"),
] + jsDependencies

let wasmProducts: [Product] = noJavaScriptKit ? [] : [
    .executable(name: "__PRODUCT__Web", targets: ["__PRODUCT__Web"]),
]
let packageProducts: [Product] = [
    .library(name: "__PRODUCT__", targets: ["__PRODUCT__"]),
    .library(name: "__PRODUCT__CoreMLResources", targets: ["__PRODUCT__CoreMLResources"]),
    .library(name: "__PRODUCT__TFLiteResources", targets: ["__PRODUCT__TFLiteResources"]),
    // Android JNI library (built by `mise run android-natives`).
    .library(name: "__PRODUCT__Android", type: .dynamic, targets: ["__PRODUCT__Android"]),
    // Native library for the Node.js server-side backend (built by
    // `mise run node-natives`). Shares the __PRODUCT__Android target: on a host triple
    // only the C ABI in `CABI.swift` compiles, since `AndroidJNI.swift` is
    // `#if os(Android)`; koffi in packages/__MODEL__-node binds the `__MODEL___*` C ABI.
    .library(name: "__PRODUCT__Node", type: .dynamic, targets: ["__PRODUCT__Android"]),
] + wasmProducts

let appleResourcePlatforms: [Platform] = [.macOS, .macCatalyst, .iOS, .tvOS, .watchOS, .visionOS]

let modelDependencies: [Target.Dependency] = [
    .product(name: "JSON", package: "desert-ant-core"),
    .product(name: "ModelStore", package: "desert-ant-core"),
    .product(name: "TextNormalization", package: "desert-ant-core"),
    .product(name: "PlatformSupport", package: "desert-ant-core"),
    .product(name: "ModelResources", package: "desert-ant-core"),
    .product(name: "Inference", package: "desert-ant-core"),
]

let packageTargets: [Target] = [
    .target(name: "__PRODUCT__", dependencies: modelDependencies),
    // Split so Apple apps do not ship the unused LiteRT model.
    .target(name: "__PRODUCT__CoreMLResources", resources: [.copy("Resources/__MODEL__.mlmodelc"), .copy("Resources/__MODEL___meta.json")]),
    .target(name: "__PRODUCT__TFLiteResources", resources: [.copy("Resources/__MODEL__.tflite"), .copy("Resources/__MODEL___meta.json")]),
    .target(
        name: "__PRODUCT__Android",
        dependencies: [
            "__PRODUCT__",
            .product(name: "FFIBuffer", package: "desert-ant-core"),
            .product(name: "HostBridge", package: "desert-ant-core", condition: .when(platforms: [.android])),
            .product(name: "ModelStore", package: "desert-ant-core", condition: .when(platforms: [.android])),
            .product(name: "PlatformSupport", package: "desert-ant-core"),
        ]
    ),
    .testTarget(name: "__PRODUCT__Tests", dependencies: ["__PRODUCT__"]),
] + (noJavaScriptKit ? [] : [
    .executableTarget(
        name: "__PRODUCT__Web",
        dependencies: [
            "__PRODUCT__",
            .product(name: "JavaScriptKit", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
            .product(name: "JavaScriptEventLoop", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
        ],
        // The wasm host bridges JavaScriptKit's non-Sendable JS values across the
        // event-loop executor; keep Swift 5 concurrency semantics here.
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
])

let package = Package(
    name: "__PRODUCT__",
    platforms: [.iOS(.v16), .macOS(.v13), .macCatalyst(.v16), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1)],
    products: packageProducts,
    dependencies: packageDependencies,
    targets: packageTargets
)
