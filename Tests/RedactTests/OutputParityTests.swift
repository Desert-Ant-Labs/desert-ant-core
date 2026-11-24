import Foundation
import Testing
import TestSupport
import Redact

#if !os(WASI)
@Suite(.serialized, .modelBacked)
struct OutputParityTests {
    private struct Case: Decodable {
        struct Item: Decodable, Equatable {
            let label, original, placeholder: String
            let start, end: Int
        }
        let name, text, redactedText: String
        let neural: Bool
        let items: [Item]
    }

    @Test func structuredOutputMatchesTheSharedFixture() async throws {
        try await checkSharedFixture(neural: false)
    }

    // The current Apple export only emits neural spans on the Neural Engine.
    #if canImport(CoreML)
    @Test(.needsNeuralEngine)
    #else
    @Test
    #endif
    func neuralOutputMatchesTheSharedFixture() async throws {
        try await checkSharedFixture(neural: true)
    }

    private func checkSharedFixture(neural: Bool) async throws {
        let url = try #require(Bundle.module.url(forResource: "output_parity", withExtension: "json"))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url)).filter { $0.neural == neural }
        try #require(!cases.isEmpty)
        let files = try await ModelFixture.files(RedactModel.self)
        let redact = Redact(directory: files.rootPath)
        for row in cases {
            let labels = try row.items.map { item in try #require(Label(rawValue: item.label)) }
            let result = try await redact.redaction(of: row.text, options: .init(labels: Set(labels)))
            let items = result.items.map { item in
                Case.Item(label: item.label.rawValue, original: item.original, placeholder: item.placeholder,
                          start: item.range.lowerBound.utf16Offset(in: row.text),
                          end: item.range.upperBound.utf16Offset(in: row.text))
            }
            #expect(result.redactedText.utf16.elementsEqual(row.redactedText.utf16), "\(row.name)")
            #expect(items == row.items, "\(row.name)")
            #expect(result.restore(result.redactedText).utf16.elementsEqual(row.text.utf16), "\(row.name)")
        }
    }
}
#endif
