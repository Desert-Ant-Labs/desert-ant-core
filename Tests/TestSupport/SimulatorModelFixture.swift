#if os(iOS) && targetEnvironment(simulator)
import Foundation
import Testing

/// Give the test its own offline model directory without sharing a simulator cache.
public func withStagedSimulatorModel(
    _ model: String, environmentKey: String, entry: String,
    run: (String) async throws -> Void
) async throws {
    let directory = try #require(ProcessInfo.processInfo.environment[environmentKey])
    let source = URL(fileURLWithPath: directory).appendingPathComponent(entry)
    let fm = FileManager.default
    let staged = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let clock = ContinuousClock()
    let start = clock.now
    try fm.createDirectory(at: staged, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: staged) }
    try fm.copyItem(at: source, to: staged.appendingPathComponent(entry))
    let inferenceStart = clock.now
    try await run(staged.path)
    print("\(model) simulator staging \(start.duration(to: inferenceStart)), load and inference \(inferenceStart.duration(to: clock.now))")
}
#endif
