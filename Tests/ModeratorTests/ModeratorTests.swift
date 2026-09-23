import Foundation
import Testing
import DesertAnt
import TestSupport
@testable import Moderator

/// Goldens come from moderator-training/models/sdk/make_sdk_goldens.py: Pillow
/// crop hashes, and the reference model's regions for a synthetic image, the committed
/// SFW fixture, and a public-domain nude painting downloaded at test time (never
/// committed).
struct ModeratorTests {
    // MARK: preprocessing, no model

#if !os(WASI)  // bundle resources are not readable under the wasm test harness
    /// The resampler reproduces Pillow's BILINEAR crops byte for byte, so the SDK
    /// scores the same pixels the model was evaluated on.
    @Test func cropsMatchPillowBitExact() async throws {
        let golden = try Golden.load()
        for entry in golden.preprocess {
            let image = Self.synthetic(width: entry.width, height: entry.height)
            let crops = try await Preprocess.crops(image, quality: try #require(Quality(name: entry.quality)))
            #expect(crops.map(Self.fnv1a) == entry.crops,
                    "\(entry.width)x\(entry.height) \(entry.quality)")
        }
    }
#endif

    @Test func cropCounts() async throws {
        let image = Self.synthetic(width: 64, height: 48)
        #expect(try await Preprocess.crops(image, quality: .fast).count == 1)
        #expect(try await Preprocess.crops(image, quality: .balanced).count == 4)
        #expect(try await Preprocess.crops(image, quality: .accurate).count == 8)
    }

    /// EXIF orientations on a 3x2 image whose pixels are their own index.
    @Test func exifOrientation() throws {
        let image = try ImagePixels(width: 3, height: 2, rgb: (0..<6).flatMap { [UInt8($0), 0, 0] })
        func red(_ p: ImagePixels) -> [UInt8] { stride(from: 0, to: p.bytes.count, by: 3).map { p.bytes[$0] } }
        // Source rows: [0 1 2] / [3 4 5].
        #expect(red(image.oriented(exif: 1)) == [0, 1, 2, 3, 4, 5])
        #expect(red(image.oriented(exif: 2)) == [2, 1, 0, 5, 4, 3])
        #expect(red(image.oriented(exif: 3)) == [5, 4, 3, 2, 1, 0])
        #expect(red(image.oriented(exif: 4)) == [3, 4, 5, 0, 1, 2])
        #expect(red(image.oriented(exif: 5)) == [0, 3, 1, 4, 2, 5])
        #expect(red(image.oriented(exif: 6)) == [3, 0, 4, 1, 5, 2])  // 90 degrees clockwise
        #expect(red(image.oriented(exif: 7)) == [5, 2, 4, 1, 3, 0])
        #expect(red(image.oriented(exif: 8)) == [2, 5, 1, 4, 0, 3])  // 90 degrees counter-clockwise
        #expect(image.oriented(exif: 6).width == 2 && image.oriented(exif: 6).height == 3)
    }

    @Test func rejectsMismatchedPixelBuffers() {
        #expect(throws: ModeratorError.self) { try ImagePixels(width: 2, height: 2, rgba: [0, 0, 0]) }
        #expect(throws: ModeratorError.self) { try ImagePixels(width: 0, height: 2, rgb: []) }
        #expect((try? ImagePixels(width: 1, height: 1, rgb: [1, 2, 3])) != nil)
    }

    @Test func policyAndThreshold() {
        let regions = Regions(nipples: 0.9, genitals: 0.1, buttocks: 0.2, nude: 0.3, sexAct: 0.05)
        #expect(Moderation(regions: regions, options: .init()).isNSFW)
        let topless = Moderation(regions: regions, options: .init(policy: .allowTopless))
        #expect(topless.score == 0.3)
        #expect(!topless.isNSFW)
        #expect(!Moderation(regions: regions, options: .init(threshold: 0.95)).isNSFW)
    }

    // MARK: end to end through the model

#if !os(WASI)
    @Suite(.serialized, .modelBacked)
    struct ModelTests {
        /// The shipped int8 Core ML / LiteRT files against the fp32 reference.
        static let tolerance = 0.02

        @Test(arguments: Quality.allCases)
        func syntheticMatchesReference(quality: Quality) async throws {
            let golden = try Golden.load()
            let image = ModeratorTests.synthetic(width: golden.synthetic.width, height: golden.synthetic.height)
            let moderator = try makeModerator()
            let result = try await moderator.analyze(image, options: .init(quality: quality))
            try expectClose(result.regions, golden.synthetic.regions(quality))
            #expect(moderator.isDownloaded())
        }

#if canImport(ImageIO)
        /// Swimwear on a beach: the hard SFW case passes.
        @Test(arguments: Quality.allCases)
        func swimwearFixtureIsSafe(quality: Quality) async throws {
            let golden = try Golden.load()
            let url = try #require(Bundle.module.url(forResource: "sfw_beach", withExtension: "png"))
            let result = try await makeModerator().analyze(contentsOf: url, options: .init(quality: quality))
            try expectClose(result.regions, golden.sfw.regions(quality))
            #expect(!result.isNSFW)
            #expect(result.score < 0.2)
        }

        /// A public-domain nude painting (Courbet) is flagged. JPEG decoders
        /// differ slightly, so this checks the decision and a looser bound.
        @Test func nudePaintingIsFlagged() async throws {
            let golden = try Golden.load()
            let data = try await Self.positiveFixture(golden)
            let moderator = try makeModerator()
            let result = try await moderator.analyze(data: data)
            #expect(result.isNSFW)
            #expect(abs(result.score - golden.positive.accurate.max) < 0.05)
            #expect(abs(result.regions.nude - golden.positive.accurate.nude) < 0.05)

            // A threshold above the score, or a policy that drops its top head,
            // changes only the decision layered on the same regions.
            let strict = try await moderator.analyze(data: data, options: .init(threshold: 0.99))
            #expect(!strict.isNSFW)
        }

        static func positiveFixture(_ golden: Golden) async throws -> Data {
            let cache = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("moderator-positive-\(golden.positive.sha256.prefix(12)).jpg")
            if let data = try? Data(contentsOf: cache), SHA256.hexDigest(data) == golden.positive.sha256 {
                return data
            }
            var request = URLRequest(url: try #require(URL(string: golden.positive.url)))
            request.setValue("DesertAntLabs-moderator-tests/1.0 (licensing@desertant.com)",
                             forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            #expect(SHA256.hexDigest(data) == golden.positive.sha256, "the fixture at \(golden.positive.url) changed")
            try data.write(to: cache)
            return data
        }
#endif

        /// `MODERATOR_MODEL_DIR` points at a local export (the directory layout
        /// the Hub revision has) until that revision is published; without it the
        /// suite resolves the pinned revision like every other model's.
        private func makeModerator() throws -> Moderator {
            if let dir = ProcessInfo.processInfo.environment["MODERATOR_MODEL_DIR"] {
                return Moderator(directory: dir)
            }
            return Moderator()
        }

        private func expectClose(_ got: Regions, _ want: Golden.Regions,
                                 sourceLocation: SourceLocation = #_sourceLocation) throws {
            let pairs = [(got.nipples, want.nipples), (got.genitals, want.genitals),
                         (got.buttocks, want.buttocks), (got.nude, want.nude), (got.sexAct, want.sexAct)]
            for (g, w) in pairs {
                #expect(abs(g - w) < Self.tolerance, "got \(got), want \(want)", sourceLocation: sourceLocation)
            }
        }
    }
#endif

    // MARK: fixtures

    /// Deterministic RGB test pattern; same formula as make_sdk_goldens.py.
    static func synthetic(width: Int, height: Int) -> ImagePixels {
        var bytes = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 3
                bytes[i] = UInt8(((x * 7 + y * 13) ^ (x * y)) & 255)
                bytes[i + 1] = UInt8((x * 3 + y * 5) & 255)
                bytes[i + 2] = UInt8(((x ^ y) * 11) & 255)
            }
        }
        return try! ImagePixels(width: width, height: height, rgb: bytes)
    }

    static func fnv1a(_ bytes: [UInt8]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

#if !os(WASI)
struct Golden: Decodable {
    struct Crops: Decodable {
        let width: Int
        let height: Int
        let quality: String
        let crops: [String]
    }

    struct Regions: Decodable {
        let nipples, genitals, buttocks, nude, sexAct: Double
        var max: Double { Swift.max(nipples, genitals, buttocks, nude, sexAct) }
    }

    struct Sample: Decodable {
        let fast, balanced, accurate: Regions
        func regions(_ q: Quality) -> Regions {
            switch q {
            case .fast: fast
            case .balanced: balanced
            case .accurate: accurate
            }
        }
    }

    struct Synthetic: Decodable {
        let width, height: Int
        let fast, balanced, accurate: Regions
        func regions(_ q: Quality) -> Regions {
            switch q {
            case .fast: fast
            case .balanced: balanced
            case .accurate: accurate
            }
        }
    }

    struct Positive: Decodable {
        let url: String
        let sha256: String
        let accurate: Regions
    }

    let preprocess: [Crops]
    let synthetic: Synthetic
    let sfw: Sample
    let positive: Positive

    static func load() throws -> Golden {
        let url = try #require(Bundle.module.url(forResource: "moderator_golden", withExtension: "json"))
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }
}

#endif

extension Quality {
    init?(name: String) {
        switch name {
        case "fast": self = .fast
        case "balanced": self = .balanced
        case "accurate": self = .accurate
        default: return nil
        }
    }
}
