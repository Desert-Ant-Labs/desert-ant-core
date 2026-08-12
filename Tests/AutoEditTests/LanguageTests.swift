import Foundation
import Testing
@testable import AutoEdit

struct WhisperLanguages {
    @Test func nothingAskedForIsDetected() throws {
        #expect(try WhisperTranscriber.code(for: nil) == nil)
    }

    @Test func aRegionResolvesToItsLanguage() throws {
        #expect(try WhisperTranscriber.code(for: Locale(identifier: "nl_BE")) == "nl")
        #expect(try WhisperTranscriber.code(for: Locale(identifier: "en_ZA")) == "en")
    }

    @Test func aLanguageWhisperCannotReadIsRefused() {
        #expect(throws: AutoEditError.self) {
            try WhisperTranscriber.code(for: Locale(identifier: "tlh"))
        }
    }

    @Test func everySupportedLanguageIsAccepted() throws {
        for language in WhisperTranscriber.supportedLanguages {
            #expect(try WhisperTranscriber.code(for: language) != nil)
        }
    }

    @Test func theListIsStableAndHasNoRepeats() {
        let identifiers = WhisperTranscriber.supportedLanguages.map(\.identifier)

        #expect(identifiers == identifiers.sorted())
        #expect(Set(identifiers).count == identifiers.count)
        #expect(identifiers.count > 90)
    }

    @Test("Javanese is Whisper's `jw`, which ICU canonicalizes to `jv`")
    func aLanguageSpelledTwoWaysIsStillOneLanguage() throws {
        #expect(WhisperTranscriber.supportedLanguages.contains(Locale(identifier: "jv")))
        #expect(try WhisperTranscriber.code(for: Locale(identifier: "jv")) == "jw")
        #expect(try WhisperTranscriber.code(for: Locale(identifier: "jw")) == "jw")
    }
}
