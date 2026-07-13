// swift-tools-version: 5.9
import PackageDescription
import Foundation

// desert-ant-core: reusable, cross-platform Swift building blocks shared by
// Desert Ant Labs' on-device model SDKs. Each module has one public API and a
// per-platform backend behind it (Apple/Linux use the OS SDK; Android and wasm
// call the host through CHostBridge), so consumers write no platform code.
//
//   Regex        stdlib-`Regex`-shaped matching, type `Pattern`
//                (NSRegularExpression | java.util.regex | JS RegExp)
//   JSON         Codable decoding (Foundation.JSONDecoder | host JSON tree | JS JSON.parse)
//   TextNormalization  String.nfkc via the platform normalizer
//                (Foundation | Android ICU unorm2 | JS String.normalize)
//   ModelStore   verified Hub downloads + platform-neutral StoredModel access
//   ModelResources  SwiftPM bundle resource loading
//   PlatformSupport environment + synchronous FFI/async bridge
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

let package = Package(
    name: "desert-ant-core",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "Regex", targets: ["Regex"]),
        .library(name: "JSON", targets: ["JSON"]),
        .library(name: "TextNormalization", targets: ["TextNormalization"]),
        .library(name: "FFIBuffer", targets: ["FFIBuffer"]),
        .library(name: "Checksum", targets: ["Checksum"]),
        .library(name: "ModelStore", targets: ["ModelStore"]),
        .library(name: "PlatformSupport", targets: ["PlatformSupport"]),
        .library(name: "ModelResources", targets: ["ModelResources"]),
        // Named-tensor inference sessions: Core ML | ONNX Runtime | JS host.
        .library(name: "Inference", targets: ["Inference"]),
        // Android JNI harness for model SDKs (empty off-Android).
        .library(name: "HostBridge", targets: ["HostBridge"]),
        // Exposed so an Android runtime's JNI shim can install the callbacks.
        .library(name: "CHostBridge", targets: ["CHostBridge"]),
    ],
    dependencies: jsDependencies,
    targets: [
        // ONNX Runtime C API (Android/Linux). Vendored header; binaries that
        // use Inference on these platforms link libonnxruntime.so themselves
        // (the SDKs vendor it per platform). Compiling needs no library, so
        // core builds and tests run without it.
        .systemLibrary(name: "COnnxRuntime"),
        .target(
            name: "Inference",
            dependencies: [
                "ModelStore",
                .target(name: "COnnxRuntime", condition: .when(platforms: [.linux, .android])),
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
        .systemLibrary(name: "CAndroidICU"),
        .target(
            name: "TextNormalization",
            dependencies: [
                .target(name: "CAndroidICU", condition: .when(platforms: [.android])),
            ] + jsWasi
        ),
        .target(name: "FFIBuffer"),
        .target(name: "Checksum"),
        .target(name: "PlatformSupport"),
        .target(name: "ModelResources"),
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

        .testTarget(name: "ChecksumTests", dependencies: ["Checksum"]),
        .testTarget(name: "PlatformSupportTests", dependencies: ["PlatformSupport"]),
        .testTarget(name: "ModelStoreTests", dependencies: ["ModelStore"]),
        .testTarget(
            name: "ModelResourcesTests",
            dependencies: ["ModelResources"],
            resources: [.copy("Resources/fixture.txt")]
        ),
        .testTarget(name: "TextNormalizationTests", dependencies: ["TextNormalization"]),
        .testTarget(name: "RegexTests", dependencies: ["Regex"]),
        .testTarget(name: "JSONTests", dependencies: ["JSON"]),
    ]
)
