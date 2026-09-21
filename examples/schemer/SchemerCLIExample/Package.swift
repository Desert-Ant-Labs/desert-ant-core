// swift-tools-version: 6.1
import PackageDescription

// A runnable command-line example: `swift run SchemerCLIExample ["some text"]`.
// The API calls are identical in an app.
let package = Package(
    name: "SchemerCLIExample",
    // The model's Core ML packages are multifunction, which needs macOS 15.
    platforms: [.macOS(.v15)],
    dependencies: [.package(name: "DesertAnt", path: "../../..")],
    targets: [
        .executableTarget(
            name: "SchemerCLIExample",
            dependencies: [.product(name: "Schemer", package: "DesertAnt")]),
    ]
)
