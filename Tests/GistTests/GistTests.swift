import Foundation
import Testing
import DesertAnt
import TestSupport
@testable import Gist

/// End-to-end tagging through the downloaded model. On Apple this runs the Core
/// ML artifact; on Linux/Windows the LiteRT artifact. Both exports come from the
/// same checkpoint, so the topics match.
#if !os(WASI)
@Suite(.modelBacked)
struct GistTests {
    /// The tagger shared by every test here — see `GistFixture` for why the
    /// suite loads the model exactly once.
    private func gist() async throws -> Gist { try await GistFixture.loaded().gist }

    private func slugs(_ text: String, topK: Int = 3) async throws -> [String] {
        try await gist().classify(text, topK: topK).map(\.slug)
    }

    @Test func englishTopics() async throws {
        let podcast = try await slugs("How to start a podcast with just your iPhone")
        #expect(podcast.contains { ["technology", "arts-entertainment"].contains($0) }, "got \(podcast)")
        let recipe = try await slugs("A one-pan roast chicken recipe for weeknights")
        #expect(recipe.contains("food-drink"), "got \(recipe)")
        let match = try await slugs("Manchester United beat Arsenal 3-1 at Old Trafford")
        #expect(match.contains("sports"), "got \(match)")
    }

    /// A known weakness, asserted so it is tracked rather than rediscovered:
    /// elliptical sports copy with no sport noun ("Late equaliser sends the
    /// semi-final to extra time") reads as `gaming`. Verified identical in the
    /// standalone gist repo before migration, so it is the model, not the port.
    /// Flip this to `sports` when a retrain fixes it.
    @Test func ellipticalSportsCopyIsMisread() async throws {
        let match = try await slugs("Late equaliser sends the semi-final to extra time")
        #expect(match == ["gaming"], "model behaviour changed - reassess this expectation")
    }

    /// The point of the multilingual build: the same story in another language
    /// lands on the same topic.
    @Test func multilingualTopics() async throws {
        let recipe = try await slugs("Recette de poulet rôti pour la semaine")
        #expect(recipe.contains("food-drink"), "got \(recipe)")
        let match = try await slugs("El equipo gana la final de la copa")
        #expect(match.contains("sports"), "got \(match)")
    }

    /// `classify` always returns the top topic even when nothing clears the tuned
    /// threshold, and never more than `topK`.
    @Test func rankingAndTopK() async throws {
        let ranked = try await gist().classify("A one-pan roast chicken recipe for weeknights", topK: 5)
        #expect(!ranked.isEmpty)
        #expect(ranked.count <= 5)
        #expect(ranked.map(\.score) == ranked.map(\.score).sorted(by: >), "topics must be ranked")
        for topic in ranked {
            #expect(!topic.name.isEmpty, "\(topic.slug) has no display name")
            #expect((0...1).contains(topic.score), "\(topic.slug) score out of range")
        }
        // An unrankable input still yields the single best topic.
        let noise = try await gist().classify("asdfgh qwerty", topK: 3)
        #expect(noise.count == 1, "got \(noise.map(\.slug))")
    }

    /// `scores` is the whole taxonomy, and it is a distribution over it.
    @Test func scoresCoverTheTaxonomy() async throws {
        let scores = try await gist().scores(of: "How to start a podcast with just your iPhone")
        #expect(scores.count == 36, "the taxonomy is 36 topics")
        for (slug, p) in scores {
            #expect((0...1).contains(p), "\(slug) = \(p) is not a probability")
        }
    }

    /// The binding payload the Kotlin and JS SDKs decode: threshold, then the
    /// whole taxonomy ordered by slug with display names attached. Guards the
    /// wire format against a change made only on the Swift side.
    @Test func bindingPayloadCarriesTheTaxonomy() async throws {
        var input = FFIWriter()
        input.string("A one-pan roast chicken recipe for weeknights")
        let bytes = try await gist().run(input: FFIReader(input.bytes), options: FFIReader([]))
        var r = FFIReader(try #require(bytes))

        let threshold = r.f64()
        #expect((0...1).contains(threshold), "threshold \(threshold) out of range")
        let count = r.u32()
        #expect(count == 36)

        var slugs: [String] = []
        for _ in 0..<count {
            let slug = r.string()
            #expect(!r.string().isEmpty, "\(slug) has no display name")
            #expect((0...1).contains(r.f64()), "\(slug) score out of range")
            slugs.append(slug)
        }
        #expect(slugs == slugs.sorted(), "the payload must be ordered by slug")
    }
}
#endif
