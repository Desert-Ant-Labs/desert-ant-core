// swift-tools-version: 6.1
import PackageDescription

// A runnable command-line example, executable with `swift run` on any machine and
// in CI, where TongueExample (the SwiftUI app) needs Xcode and a simulator. The
// API calls are identical in a view.
//
// The dependency is named explicitly rather than relying on the identity SwiftPM
// derives from the checkout directory: that identity is the folder's basename, so
// a bare `.package(path:)` would only resolve for whoever happened to clone into a
// folder of the matching name.
let package = Package(
    name: "TongueCLIExample",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "DesertAnt", path: "../../..")],
    targets: [
        .executableTarget(name: "TongueCLIExample", dependencies: [.product(name: "Tongue", package: "DesertAnt")]),
    ]
)
