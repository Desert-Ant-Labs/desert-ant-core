import DesertAnt
import Foundation

@testable import Ear

/// Where the model and the audio live, for the suites that need real files.
///
/// These are downloads rather than fixtures, so the suites that use them are
/// gated on their presence. The gate is a trait on the suite rather than an
/// early `return` inside it, because a suite that returns early reports a pass,
/// and a pass that verified nothing is indistinguishable from one that did.
/// Three suites here reported passing in CI while doing exactly nothing.
///
/// It lives outside the suites because a suite's own trait cannot refer to the
/// type it is defining.
enum EarFixtures {
    /// A directory holding this platform's model files.
    ///
    /// Checked against the artifact the catalog names for the platform in hand,
    /// not against the Core ML one: on Linux the file is `ear.tflite`, and
    /// hardcoding `ear.mlmodelc` silently skipped every accuracy test off Apple
    /// while reporting that the suite had run.
    static var modelDirectory: String? {
        let path = ProcessInfo.processInfo.environment["EAR_MODEL_DIR"]
            ?? NSHomeDirectory() + "/work/ear/model"
        let expanded = NSString(string: path).expandingTildeInPath
        let artifact = EarModel.artifact(for: .current)
        return FileManager.default.fileExists(atPath: expanded + "/" + artifact)
            ? expanded : nil
    }

    static var filterbank: [UInt8]? {
        guard let directory = modelDirectory,
              let data = try? Data(contentsOf:
                URL(fileURLWithPath: directory + "/mel_filters.f32"))
        else { return nil }
        return [UInt8](data)
    }

    /// `<language>__<name>.wav`, so the expected answer travels with the file.
    static var recordings: [(language: String, path: String)] {
        let path = ProcessInfo.processInfo.environment["EAR_AUDIO_DIR"]
            ?? NSHomeDirectory() + "/work/e2e"
        let expanded = NSString(string: path).expandingTildeInPath
        let names = (try? FileManager.default.contentsOfDirectory(atPath: expanded)) ?? []
        return names.filter { $0.hasSuffix(".wav") && $0.contains("__") }
            .sorted()
            .map { (String($0.split(separator: "_")[0]), expanded + "/" + $0) }
    }

    static var canRunEndToEnd: Bool { modelDirectory != nil && !recordings.isEmpty }
    static var hasFilterbank: Bool { filterbank != nil }
    static var downloadEnabled: Bool {
        ProcessInfo.processInfo.environment["EAR_TEST_DOWNLOAD"] == "1"
    }
}
