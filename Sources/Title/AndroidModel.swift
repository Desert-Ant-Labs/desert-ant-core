#if os(Android)
import Android
import CTitleRuntime
import DesertAnt
import Synchronization

private final class LiteRTTitle: @unchecked Sendable {
    private static let contextTokens: Int32 = 1280
    private static let outputTokens: Int32 = 96
    private let engine: OpaquePointer
    private let lock = Mutex(())

    init(path: String) throws {
        var error = [CChar](repeating: 0, count: 512)
        guard let engine = dal_title_open(path, Self.contextTokens, &error, error.count) else {
            throw InferenceError.sessionUnavailable(Self.message(error))
        }
        self.engine = engine
        licenseOnLoad(TitleModel.sdkInfo)
    }

    deinit { dal_title_close(engine) }

    func describe(_ text: String) throws -> Card {
        try lock.withLock { _ in
            try Task.checkCancellation()
            // Leave room for the runtime's start token as well as the reply.
            let budget = Int(Self.contextTokens - Self.outputTokens - 1)
            guard let prompt = try Titles.fittedAndroidPrompt(text, budget: budget, tokenCount: tokenCount) else {
                throw InferenceError.runFailed("Title's instructions exceed the context budget")
            }
            var error = [CChar](repeating: 0, count: 512)
            guard let reply = dal_title_generate(engine, prompt, prompt.utf8.count, Self.outputTokens,
                                                 &error, error.count) else {
                throw InferenceError.runFailed(Self.message(error))
            }
            defer { free(reply) }
            try Task.checkCancellation()
            return Titles.parse(String(cString: reply))
        }
    }

    private func tokenCount(_ prompt: String) throws -> Int {
        var error = [CChar](repeating: 0, count: 512)
        let count = dal_title_token_count(engine, prompt, &error, error.count)
        guard count >= 0 else { throw InferenceError.runFailed(Self.message(error)) }
        return Int(count)
    }

    private static func message(_ bytes: [CChar]) -> String {
        bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}

final class TitleAndroidModel: BoundModel {
    private let model: LoadedModel<LiteRTTitle>

    init(cacheRoot: String?, directory: String?) {
        model = LoadedModel(TitleModel.self, directory: directory, cacheRoot: cacheRoot) { files in
            try LiteRTTitle(path: files.path(TitleModel.liteRTBundle))
        }
    }

    func isDownloaded() -> Bool { model.isDownloaded() }

    func download(progress: @Sendable @escaping (Double) -> Void) async throws {
        do {
            try await model.download(progress: progress)
        } catch {
            Self.log(error)
            throw error
        }
    }

    // Input: one string. Output: title and description strings.
    func run(input: FFIReader, options: FFIReader) async -> [UInt8]? {
        var input = input
        let text = input.string()
        do {
            let card = try await model.value().describe(text)
            var result = FFIWriter()
            result.string(card.title)
            result.string(card.description)
            return result.bytes
        } catch {
            Self.log(error)
            return nil
        }
    }

    private static func log(_ error: any Error) {
        Log.log(.error, (error as? InferenceError)?.message ?? String(describing: error), source: "Title")
    }
}

enum TitleBinding: ModelBinding {
    static let id = TitleModel.id

    static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        TitleAndroidModel(cacheRoot: cacheRoot, directory: directory)
    }
}
#endif
