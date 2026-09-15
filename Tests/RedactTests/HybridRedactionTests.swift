import Testing
import DesertAnt
@_spi(RedactBindings) import Redact

struct HybridRedactionTests {
    private let text = "😀 call +34 600 100 200 or email me@x.com iban DE89370400440532013000 card 4539 1488 0343 6467"

    @Test func phoneOnlyRedactionKeepsStructuredMatchesOutOfNeuralInput() async throws {
        let session = NoEntitiesSession()
        let redact = Redact(assets: ModelAssets(
            tokenizer: tokenizer(), labelsJSON: "{\"id2label\":{\"0\":\"O\"}}", session: session
        ))
        let result = try await redact.redaction(of: text, options: .init(labels: [.phone]))

        #expect(result.redactedText == "😀 call [PHONE_1] or email me@x.com iban DE89370400440532013000 card 4539 1488 0343 6467")
        let item = try #require(result.items.first)
        #expect(result.items.count == 1)
        #expect(item.label == .phone)
        #expect(item.original == "+34 600 100 200")
        #expect(item.confidence == 0.92)
        #expect(item.range.lowerBound.utf16Offset(in: text) == 8)
        #expect(item.range.upperBound.utf16Offset(in: text) == 23)
        #expect(result.restore(result.redactedText) == text)
        #expect(await session.inputIDs == [1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 2])
    }

    @Test func structuredAndPhoneRedactionsKeepTheirOriginalRanges() async throws {
        let session = NoEntitiesSession()
        let redact = Redact(assets: ModelAssets(
            tokenizer: tokenizer(), labelsJSON: "{\"id2label\":{\"0\":\"O\"}}", session: session
        ))
        let result = try await redact.redaction(of: text)

        #expect(result.redactedText == "😀 call [PHONE_1] or email [EMAIL_1] iban [BANK_ACCOUNT_1] card [CREDIT_CARD_1]")
        #expect(result.items.map(\.label) == [.phone, .email, .bankAccount, .creditCard])
        #expect(result.items.map(\.original) == ["+34 600 100 200", "me@x.com", "DE89370400440532013000", "4539 1488 0343 6467"])
        #expect(result.items.map(\.confidence) == [0.92, 1, 1, 1])
        #expect(result.items.map { $0.range.lowerBound.utf16Offset(in: text) } == [8, 33, 47, 75])
        #expect(result.items.map { $0.range.upperBound.utf16Offset(in: text) } == [23, 41, 69, 94])
        #expect(result.restore(result.redactedText) == text)
        #expect(await session.inputIDs == [1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 2])
    }

    @Test func neuralPhoneMatchReplacesTheOverlappingDeterministicMatch() async throws {
        let redact = Redact(assets: ModelAssets(
            tokenizer: tokenizer(),
            labelsJSON: "{\"id2label\":{\"0\":\"O\",\"1\":\"B-PHONE\",\"2\":\"I-PHONE\",\"3\":\"E-PHONE\"}}",
            session: PhoneSession()
        ))
        let result = try await redact.redaction(of: text, options: .init(labels: [.phone]))

        let item = try #require(result.items.first)
        #expect(result.items.count == 1)
        #expect(item.label == .phone)
        #expect(item.original == "+34 600 100 200")
        #expect(item.confidence > 0.99 && item.confidence <= 1)
        #expect(item.range.lowerBound.utf16Offset(in: text) == 8)
        #expect(item.range.upperBound.utf16Offset(in: text) == 23)
        #expect(result.redactedText == "😀 call [PHONE_1] or email me@x.com iban DE89370400440532013000 card 4539 1488 0343 6467")
        #expect(result.restore(result.redactedText) == text)
    }

    private func tokenizer() -> [UInt8] {
        let pieces = ["<unk>", "<s>", "</s>", "▁😀", "▁call", "▁+34", "▁600", "▁100", "▁200", "▁or", "▁email", "▁iban", "▁card"]
        var bytes: [UInt8] = [0x52, 0x44, 0x54, 0x4B, 1]
        for value: UInt32 in [0, 1, 2, UInt32(pieces.count)] {
            bytes += (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        bytes += [UInt8](repeating: 0, count: pieces.count * 4)
        for piece in pieces {
            let count = UInt16(piece.utf8.count)
            bytes += [UInt8(truncatingIfNeeded: count), UInt8(truncatingIfNeeded: count >> 8)]
        }
        for piece in pieces { bytes += piece.utf8 }
        return bytes
    }
}

private struct PhoneSession: InferenceSession {
    func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) async throws -> [Tensor] {
        let ids = try #require(inputs["input_ids"]?.int32Values)
        var logits = [Float](repeating: 0, count: 256 * 4)
        for (row, id) in ids.enumerated() {
            let label: Int
            switch id {
            case 5: label = 1
            case 6, 7: label = 2
            case 8: label = 3
            default: label = 0
            }
            logits[row * 4 + label] = 20
        }
        return [Tensor(float32: logits, shape: [1, 256, 4])]
    }
}

private actor NoEntitiesSession: InferenceSession {
    private(set) var inputIDs: [Int32] = []

    func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) async throws -> [Tensor] {
        let ids = try #require(inputs["input_ids"]?.int32Values)
        let mask = try #require(inputs["attention_mask"]?.int32Values)
        inputIDs = zip(ids, mask).filter { $0.1 != 0 }.map { $0.0 }
        return [Tensor(float32: [Float](repeating: 0, count: 256), shape: [1, 256, 1])]
    }
}
