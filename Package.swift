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
        .library(name: "FFIBuffer", targets: ["FFIBuffer"]),
        // Android JNI harness for model SDKs (empty off-Android).
        .library(name: "HostBridge", targets: ["HostBridge"]),
        // Exposed so an Android runtime's JNI shim can install the callbacks.
        .library(name: "CHostBridge", targets: ["CHostBridge"]),
    ],
    dependencies: jsDependencies,
    targets: [
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
        .target(name: "FFIBuffer"),
        .target(
            name: "HostBridge",
            dependencies: [
                "FFIBuffer",
                .target(name: "CHostBridge", condition: .when(platforms: [.android])),
            ]
        ),

        .testTarget(name: "RegexTests", dependencies: ["Regex"]),
        .testTarget(name: "JSONTests", dependencies: ["JSON"]),
    ]
)
