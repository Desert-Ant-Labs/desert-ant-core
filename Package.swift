// swift-tools-version: 5.9
import PackageDescription

// desert-ant-core: reusable, cross-platform Swift building blocks shared by
// Desert Ant Labs' on-device model SDKs. Each module has one public API and a
// per-platform backend behind it (Apple/Linux use the OS SDK; Android and wasm
// call the host through CHostBridge), so consumers write no platform code.
//
//   Regex        stdlib-`Regex`-shaped matching (NSRegularExpression | java.util.regex | JS RegExp)
//   JSON         Codable decoding      (Foundation.JSONDecoder | host JSON tree | JS JSON.parse)
//   CHostBridge  generic host-callback bridge a runtime shim installs on Android

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
        // Exposed so an Android runtime's JNI shim can install the callbacks.
        .library(name: "CHostBridge", targets: ["CHostBridge"]),
    ],
    dependencies: [
        // JS interop for the WebAssembly backends (browser / node).
        .package(url: "https://github.com/swiftwasm/JavaScriptKit", from: "0.56.1"),
    ],
    targets: [
        .target(
            name: "Regex",
            dependencies: [
                .target(name: "CHostBridge", condition: .when(platforms: [.android])),
                .product(name: "JavaScriptKit", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
            ]
        ),
        .target(
            name: "JSON",
            dependencies: [
                .target(name: "CHostBridge", condition: .when(platforms: [.android])),
                .product(name: "JavaScriptKit", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
            ]
        ),
        .target(name: "CHostBridge"),

        .testTarget(name: "RegexTests", dependencies: ["Regex"]),
        .testTarget(name: "JSONTests", dependencies: ["JSON"]),
    ]
)
