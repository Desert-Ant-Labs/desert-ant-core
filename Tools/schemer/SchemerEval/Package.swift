// swift-tools-version: 6.1
import PackageDescription

// Batch evaluation of the shipped Swift pipeline: reads eval records as JSONL,
// runs `Schemer.extract` on each, and writes the predictions as JSONL for the
// training repo's scorer (schemer-training tools/bench/swift/score_swift.py).
// This is how the model is measured: through the code that ships, not a port.
let package = Package(
    name: "SchemerEval",
    platforms: [.macOS(.v15)],
    dependencies: [.package(name: "DesertAnt", path: "../../..")],
    targets: [
        .executableTarget(
            name: "SchemerEval",
            dependencies: [.product(name: "Schemer", package: "DesertAnt")]),
    ]
)
