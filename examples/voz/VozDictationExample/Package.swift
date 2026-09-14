// swift-tools-version: 6.1
import PackageDescription

// A runnable command-line example of Voz.Live, the dictation path. It feeds a
// file through the streaming API at the pace a microphone would, so the latency
// it prints is the latency a dictation app would see. Running flat out instead
// would report a number nobody experiences: the SoC clocks down when it is
// mostly idle, which a streaming workload always is.
//
// The dependency is named explicitly rather than relying on the identity SwiftPM
// derives from the checkout directory: that identity is the folder's basename, so
// a bare `.package(path:)` would only resolve for whoever happened to clone into a
// folder of the matching name.
let package = Package(
    name: "VozDictationExample",
    platforms: [.macOS(.v15)],
    dependencies: [.package(name: "DesertAnt", path: "../../..")],
    targets: [
        .executableTarget(name: "VozDictationExample",
                          dependencies: [.product(name: "Voz", package: "DesertAnt")]),
    ]
)
