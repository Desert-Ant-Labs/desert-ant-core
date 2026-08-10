#if canImport(Speech) && canImport(AVFoundation) && canImport(CoreMedia)
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

/// A SpeechTranscriber result with corrected word-level timestamps.
///
/// It preserves the familiar `text`, `range`, `resultsFinalizationTime`, and `isFinal`
/// surface. The original Apple result remains available for alternatives and other metadata.
@available(iOS 26, macOS 26, tvOS 26, visionOS 26, *)
public struct RefinedSpeechResult: SpeechModuleResult, Sendable, CustomStringConvertible {
    public let original: SpeechTranscriber.Result
    public let text: AttributedString
    public let words: [WordTiming]

    public var range: CMTimeRange { original.range }
    public var resultsFinalizationTime: CMTime { original.resultsFinalizationTime }
    public var refinedWordCount: Int { words.lazy.filter(\.refined).count }
    public var description: String { String(text.characters) }

    init(original: SpeechTranscriber.Result, text: AttributedString, words: [WordTiming]) {
        self.original = original
        self.text = text
        self.words = words
    }
}

@available(iOS 26, macOS 26, tvOS 26, visionOS 26, *)
public extension SpeechTimestampRefiner {
    /// Record a transcriber's result and return the same familiar result surface with corrected
    /// timestamps. Volatile results pass through; finalized results are refined.
    func refine(_ result: SpeechTranscriber.Result) -> RefinedSpeechResult {
        let originalWords = words(from: result.text)
        guard result.isFinal else {
            return RefinedSpeechResult(original: result, text: result.text, words: originalWords)
        }
        let correctedWords = refine(originalWords)
        return RefinedSpeechResult(
            original: result,
            text: Self.apply(correctedWords, to: result.text),
            words: correctedWords
        )
    }

    /// Buffer audio for timestamp refinement and create the AnalyzerInput passed to Apple.
    /// This combines the two operations needed in callback-based audio pipelines.
    func analyzerInput(_ buffer: AVAudioPCMBuffer, at startTime: CMTime? = nil) -> AnalyzerInput {
        appendAudio(buffer)
        return AnalyzerInput(buffer: buffer, bufferStartTime: startTime)
    }
}

@available(iOS 26, macOS 26, tvOS 26, visionOS 26, *)
public extension AsyncSequence where Element == AnalyzerInput {
    /// Pass analyzer inputs through unchanged while recording their audio for refinement.
    func recordingAudio(
        for refiner: SpeechTimestampRefiner
    ) -> AsyncMapSequence<Self, AnalyzerInput> {
        map { input in
            refiner.appendAudio(input.buffer)
            return input
        }
    }
}

@available(iOS 26, macOS 26, tvOS 26, visionOS 26, *)
public extension AsyncSequence where Element == SpeechTranscriber.Result {
    /// Transform Apple's result stream into the same result surface with corrected timestamps.
    /// Volatile results pass through unchanged; finalized results are refined.
    func refiningTimestamps(
        with refiner: SpeechTimestampRefiner
    ) -> AsyncMapSequence<Self, RefinedSpeechResult> {
        map { result in refiner.refine(result) }
    }
}
#endif
