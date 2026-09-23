// swift-tools-version: 6.1
import PackageDescription

// A runnable command-line example: `swift run ModeratorCLIExample <image>...`.
// The API calls are identical in an app.
let package = Package(
    name: "ModeratorCLIExample",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "DesertAnt", path: "../../..")],
    targets: [
        .executableTarget(
            name: "ModeratorCLIExample",
            dependencies: [.product(name: "Moderator", package: "DesertAnt")]),
    ]
)
