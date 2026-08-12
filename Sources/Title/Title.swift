import DesertAnt
import Foundation
import Transcript

// Everything MLX-backed is behind `#if MLX`, the compilation condition SwiftPM defines for the
// `MLX` package trait (see Package.swift). Without the trait this module still compiles —
// `Card`, the prompt, and `parse` are portable and tested everywhere — but generation is
// absent: `Titles` has no public initializer, so a consumer that forgot the trait fails at
// compile time instead of mis-building.
#if MLX
// `HuggingFace` and `Tokenizers` are imported for the MACRO, not for this file's own code:
// `#huggingFaceLoadModelContainer` expands into references to `HubClient` and `Tokenizers`.
// Removing them as "unused" breaks the build inside a macro expansion, where the error names
// symbols that appear nowhere in this source.
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers
#endif

/// A title and a description for a passage of text.
///
/// Owned by `Title`, deliberately, and NOT a field on ``Transcript/Clip``. Selection and card
/// writing are separate stages on separate silicon, and a `card` property hanging off every
/// `Clip` would be permanently nil for the many consumers that never call this module — the
/// same reasoning that keeps `Title` a separate product. Pair them with ``Titles/cards(for:)``
/// when you want both.
public struct Card: Sendable, Codable, Equatable {
    public let title: String
    public let description: String

    public init(title: String, description: String) {
        self.title = title
        self.description = description
    }

    /// True when the model returned neither a title nor a description. Parsing is deliberately
    /// tolerant (see ``Titles/parse(_:)``), so an empty card is the only failure signal a
    /// caller gets, and it should be treated as "no card" rather than as an error.
    public var isEmpty: Bool { title.isEmpty && description.isEmpty }
}

/// Writes titles and descriptions on device.
///
/// **Not clip-specific.** The model was fine-tuned on transcript clips, but the task it learned
/// is general. Measured Aug 2026 on the 6-bit Granite against a transcript clip, a news
/// paragraph, a product description and an internal email: all four produced accurate,
/// specific, correctly-registered cards. One slip in four — an email saying "moving the review
/// from Tuesday to Thursday" was described as running "from Tuesday to Thursday" — so treat it
/// as capable on general prose, not infallible on it.
///
/// Loading is expensive and generation is cheap: build one and reuse it. An `actor` because MLX
/// state is not safe to drive from several tasks at once.
///
/// This type does NOT go through `InferenceSession`. It is the one model in this package that
/// runs on MLX, for reasons recorded on ``TitleModel``.
public actor Titles {

    /// The prompt the model is fine-tuned against, byte for byte.
    ///
    /// The single definition is `title-training/python/student_prompt.py`, which `train.py`
    /// imports to build every training example and which `tests/test_prompt_parity.py` compares
    /// against THIS string. If they drift, that test fails.
    ///
    /// **The previous version of this property was a different string from the one training
    /// used**, and the divergence was invisible from either side. Training used a short
    /// instruction; this sent a long RULES block whose docstring sourced it to a
    /// `gen_factual_batch.py` that does not exist. So the shipped model was served an unseen
    /// prompt on every call, and the rule this block spent four lines on —
    /// `NEVER begin with "The video", "This clip", "The speaker"` — had never appeared in a
    /// training example and could not have been learned. The model went on producing those
    /// openers at roughly the rate its TARGETS contained them, which is where the fix belongs.
    ///
    /// It says "passage" rather than "video clip" because the model is not clip-specific and
    /// the old wording made every non-video caller send instructions about a video.
    ///
    /// No RULES block. Rules shape the TEACHER's output and therefore the targets; a student
    /// that has learned the mapping does not need them recited, and reciting them costs prompt
    /// tokens on every call. The teacher's prompt lives in `title-training/python/gen_cards.py`.
    static let prompt = """
        Write a factual title (3-8 words) and a 1-2 sentence description for this passage.\
        Be specific enough to identify this passage. No emoji, no hashtags, no hype.\
        Write in the same language as the passage.

        PASSAGE:
        {clip}
        """

    #if MLX
    private let model: ModelContainer
    private let maxTokens: Int

    /// - Parameters:
    ///   - directory: an MLX model folder — the files ``TitleModel/files`` declares. Nothing is
    ///     bundled with this package and nothing is downloaded here; point this at a folder you
    ///     populated.
    ///   - maxTokens: two short lines. The cap stops a degenerate run decoding forever, which
    ///     is a real failure mode for a small instruct model given unusual input.
    public init(directory: URL, maxTokens: Int = 96) async throws {
        self.model = try await #huggingFaceLoadModelContainer(
            configuration: ModelConfiguration(directory: directory))
        self.maxTokens = maxTokens
    }

    /// A title and description for any passage of text.
    public func describe(_ text: String) async throws -> Card {
        Self.parse(try await generate(
            Self.prompt.replacingOccurrences(of: "{clip}", with: text)))
    }

    /// A card for one clip.
    public func card(for clip: Clip) async throws -> Card {
        try await describe(clip.text)
    }

    /// Cards for many clips, index-aligned with the input.
    ///
    /// Returns a parallel array rather than mutating `Clip`, so `Clips` stays unaware that this
    /// module exists. Zip them if you want pairs.
    ///
    /// Sequential on purpose. Decode is already GPU-bound, so overlapping generations contend
    /// for the same device rather than adding throughput, and on a phone it adds thermal
    /// pressure that shows up as throttling partway through a long video.
    public func cards(for clips: [Clip]) async throws -> [Card] {
        var out: [Card] = []
        out.reserveCapacity(clips.count)
        for clip in clips {
            out.append(try await card(for: clip))
        }
        return out
    }

    private func generate(_ prompt: String) async throws -> String {
        try await model.perform { context in
            let input = try await context.processor.prepare(
                input: UserInput(messages: [["role": "user", "content": prompt]]))
            // The AsyncStream `generate` — the callback variants are deprecated. The token cap
            // moved into `GenerateParameters.maxTokens`, which stops the iterator itself; the
            // old visitor returned `.stop` at the same count.
            var text = ""
            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(
                    maxTokens: self.maxTokens,
                    temperature: 0.0    // deterministic cards
                ),
                context: context
            )
            for await generation in stream {
                if case let .chunk(chunk) = generation {
                    text += chunk
                }
            }
            return text
        }
    }
    #endif

    /// Pull TITLE/DESC out of the reply.
    ///
    /// Tolerant by design: a card model that drifts off format should degrade to a usable title
    /// rather than throw, because the clip itself is still good and selection is what ships.
    /// `DESC` and `DESCRIPTION` are both accepted — the training data uses `DESC`, but
    /// base-model habits leak the longer spelling through.
    static func parse(_ raw: String) -> Card {
        var title = "", description = ""
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let upper = trimmed.uppercased()
            if upper.hasPrefix("TITLE:") {
                title = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if upper.hasPrefix("DESCRIPTION:") {
                description = String(trimmed.dropFirst(12)).trimmingCharacters(in: .whitespaces)
            } else if upper.hasPrefix("DESC:") {
                description = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if title.isEmpty && !trimmed.isEmpty {
                // No label at all: take the first real line as the title rather than nothing.
                title = trimmed
            }
        }
        return Card(title: title, description: description)
    }
}
