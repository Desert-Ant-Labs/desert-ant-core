#if canImport(Speech)
import Align
import AVFoundation
import Foundation
import Speech
import Transcript

/// Transcribes with the system's speech recognizer, refining word timings with
/// Align.
///
/// The recognizer's assets are installed on first use for a locale and kept by
/// the system, shared with every app that asks for them.
@available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
public struct AppleTranscriber: Transcribing {
    /// Whether word timings are refined after recognition.
    public let refinesTimings: Bool

    /// Creates a transcriber.
    ///
    /// - Parameter refinesTimings: Whether to correct the recognizer's
    ///   word-level timings with Align. Locales Align does not cover keep the
    ///   recognizer's own timings.
    public init(refinesTimings: Bool = true) {
        self.refinesTimings = refinesTimings
    }

    /// The locales the system can transcribe, in a stable order. These are
    /// regional: `en-US` and `en-GB` rather than `en`.
    public var supportedLanguages: [Locale] {
        get async {
            await SpeechTranscriber.supportedLocales
                .sorted { $0.identifier(.bcp47) < $1.identifier(.bcp47) }
        }
    }

    public func transcribe(
        _ url: URL,
        language: Locale?,
        progress: @escaping TranscriptionProgressHandler
    ) async throws -> Transcription {
        progress(TranscriptionProgress(phase: .loadingModel, fraction: 0))
        let locale = try await Self.supportedLocale(for: language ?? Locale.current)
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        try await install(transcriber)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)

        let refiner = refinesTimings
            ? try? SpeechTimestampRefiner(locale: locale, audioFile: file)
            : nil

        // The recognizer reports finalized passages rather than a percentage,
        // so how far into the recording it has read is the fraction.
        let seconds = file.fileFormat.sampleRate > 0
            ? Double(file.length) / file.fileFormat.sampleRate
            : 0
        progress(TranscriptionProgress(phase: .transcribing, fraction: 0))

        async let started: Void = analyzer.start(inputAudioFile: file, finishAfterFile: true)

        var words: [TimedWord] = []
        func take(_ text: AttributedString) {
            words.append(contentsOf: Self.words(in: text))
            guard seconds > 0, let end = words.last?.end else { return }
            progress(TranscriptionProgress(phase: .transcribing,
                                           fraction: min(1, end / seconds)))
        }

        if let refiner {
            for try await result in transcriber.results.refiningTimestamps(with: refiner) {
                guard result.isFinal else { continue }
                take(result.text)
            }
        } else {
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                take(result.text)
            }
        }
        try await started

        guard !words.isEmpty else { throw AutoEditError.noSpeech }
        progress(TranscriptionProgress(phase: .transcribing, fraction: 1))
        return Transcription(words: words, language: locale)
    }

    /// Returns the supported locale to transcribe `wanted` with.
    ///
    /// The system's locales are regional. A request for a bare language, or for
    /// a region the system does not carry, resolves to the first supported
    /// region of the same language, so `en` and `en-IE` both reach an English
    /// recognizer.
    ///
    /// - Throws: ``AutoEditError/unsupported(_:)`` when the system carries no
    ///   recognizer for the language.
    static func supportedLocale(for wanted: Locale) async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        if let exact = supported.first(where: { $0.identifier(.bcp47) == wanted.identifier(.bcp47) }) {
            return exact
        }
        guard let code = wanted.language.languageCode?.identifier,
              let sameLanguage = supported.first(where: { $0.language.languageCode?.identifier == code })
        else {
            throw AutoEditError.unsupported("the system cannot transcribe \(wanted.identifier)")
        }
        return sameLanguage
    }

    /// Downloads and installs the recognizer's assets.
    private func install(_ transcriber: SpeechTranscriber) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    /// Reads the timed runs out of a recognized passage.
    private static func words(in text: AttributedString) -> [TimedWord] {
        text.runs.compactMap { run in
            guard let span = run.audioTimeRange else { return nil }
            return TimedWord(text: String(text[run.range].characters),
                             start: span.start.seconds,
                             end: span.end.seconds)
        }
    }
}
#endif
