import Testing
@testable import Inference
import PlatformSupport

#if canImport(COnnxRuntime)
import COnnxRuntime
import CStrings
import Foundation

// What the shim's logger received: a C callback cannot capture, so it records
// here. Other suites create sessions at the same time and are recorded too, which
// is why the assertions look for a line rather than count them.
private let recordedLock = NSLock()
private nonisolated(unsafe) var recorded: [(Int32, String)] = []

/// The runtime's own lines reach the shim's logger with ORT's severity instead
/// of standard error. Creating a session logs a line per session, so the test
/// does not depend on being the first in the process to create the environment.
@Suite(.serialized)
struct OnnxLogTests {
    @Test func sessionLinesReachTheLoggerWithTheirSeverity() throws {
        let url = try #require(Bundle.module.url(forResource: "testmodel", withExtension: "onnx"))
        // The session's init installs the SDK's logger on its first run in the
        // process, which would replace the recorder installed below.
        _ = onnxRuntimeLogsThroughLog
        recordedLock.withLock { recorded = [] }
        dal_ort_set_logger { severity, message in
            guard let message else { return }
            let text = decodeCString(message)
            recordedLock.withLock { recorded.append((severity, text)) }
        }
        defer { installOnnxRuntimeLogger() }
        _ = try OnnxSession(modelPath: url.path, accelerator: .cpu)
        let lines = recordedLock.withLock { recorded }
        #expect(lines.contains { $0.0 == 1 && $0.1.contains("Session successfully initialized") })
    }

    @Test func severitiesMapToLevels() {
        #expect(onnxRuntimeLogLevel(0) == .debug)
        #expect(onnxRuntimeLogLevel(1) == .info)
        #expect(onnxRuntimeLogLevel(2) == .warning)
        #expect(onnxRuntimeLogLevel(3) == .error)
        #expect(onnxRuntimeLogLevel(4) == .error)
    }
}
#endif
