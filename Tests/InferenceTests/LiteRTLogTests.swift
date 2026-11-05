import Testing
@testable import Inference
import PlatformSupport

#if canImport(CLiteRt)
import CLiteRt
import CStrings
import Foundation

// What the shim's logger received: a C callback cannot capture, so it records
// here. Other suites compile models at the same time and land here too, which
// is why the assertions look for a line rather than count them.
private let recordedLock = NSLock()
private nonisolated(unsafe) var recorded: [(Int32, String)] = []

/// The runtime's own lines reach the shim's logger with the severity their
/// prefix named and the prefix gone, instead of file descriptor 2 (issue #247).
/// Compiling a model logs one line per model, so the test does not depend on
/// being the first in the process to create the environment.
@Suite(.serialized)
struct LiteRTLogTests {
    @Test func compileLinesReachTheLoggerWithTheirSeverity() throws {
        let url = try #require(Bundle.module.url(forResource: "testmodel", withExtension: "tflite"))
        // The model's init installs the SDK's logger on its first run in the
        // process, which would replace the recorder installed below.
        _ = litertLogsThroughLog
        recordedLock.withLock { recorded = [] }
        dal_lrt_set_logger { severity, message in
            guard let message else { return }
            let text = decodeCString(message)
            recordedLock.withLock { recorded.append((severity, text)) }
        }
        defer { installLiteRTLogger() }
        _ = try LiteRTModel(modelPath: url.path, accelerator: .cpu)
        let lines = recordedLock.withLock { recorded }
        #expect(lines.contains { $0.0 == 1 && $0.1.contains("Flatbuffer model initialized") })
        #expect(lines.allSatisfy { !$0.1.hasPrefix("INFO: ") && !$0.1.hasPrefix("WARNING: ") })
    }

    @Test func severitiesMapToLevels() {
        #expect(litertLogLevel(-1) == .debug)
        #expect(litertLogLevel(0) == .debug)
        #expect(litertLogLevel(1) == .info)
        #expect(litertLogLevel(2) == .warning)
        #expect(litertLogLevel(3) == .error)
        #expect(litertLogLevel(9) == .error)
    }
}
#endif
