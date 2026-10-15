import Foundation
import Testing
import DesertAnt
import TestSupport
@testable import Eye

/// Goldens come from ml-eye's `scripts/sdk_goldens.py`: Pillow's model inputs for
/// synthetic images as byte hashes, and the analysis of a public-domain photo (the
/// beach scene Moderator's suite uses, stored as raw gray bytes so every platform
/// reads it) through `eye.tflite`, decoded as ml-eye decodes it.
struct EyeTests {
    // MARK: preprocessing, no model

#if !os(WASI)  // bundle resources are not readable under the wasm test harness
    /// Every model input reproduces Pillow byte for byte, so the SDK scores the
    /// same pixels the model was evaluated on.
    @Test func inputsMatchPillowBitExact() throws {
        let golden = try Golden.load()
        for g in golden.preprocess {
            let image = Preprocess.rgb(Self.synthetic(width: g.width, height: g.height))
            let label = "\(g.width)x\(g.height)"
            #expect(Self.fnv1a(Preprocess.centreCrop(image).bytes) == g.centre, "centre \(label)")
            #expect(Self.fnv1a(Preprocess.squash(image).bytes) == g.squash, "squash \(label)")
            #expect(Self.fnv1a(Preprocess.letterbox(image).0.bytes) == g.letterbox, "letterbox \(label)")
            let b = g.faceBox
            #expect(Self.fnv1a(Preprocess.faceCrop(image, box: (b[0], b[1], b[2], b[3])).bytes) == g.face, "face \(label)")
            let (gray, function) = Preprocess.sharp(image)
            #expect(function == g.sharpFunction, "sharp shape \(label)")
            #expect(Self.fnv1a(gray.bytes) == g.sharp, "sharp \(label)")
        }
    }
#endif

    /// The threaded, vectorized resizer against the plain port, byte for byte:
    /// down and up, each pass alone and both, 1 and 3 channels, every filter,
    /// sizes large enough to split across threads.
    @Test func resizeMatchesThePlainPort() {
        for (w, h) in [(4032, 3024), (3024, 4032), (1000, 7), (5, 900), (640, 480)] {
            let rgb = Preprocess.rgb(Self.synthetic(width: w, height: h))
            for image in [rgb, Preprocess.gray(rgb)] {
                for filter in [Preprocess.Filter.bilinear, .bicubic, .lanczos] {
                    for (ow, oh) in [(384, 384), (675, 384), (w, 384), (384, h), (768, 576), (1999, 13)] {
                        let got = Preprocess.resize(image, width: ow, height: oh, filter: filter)
                        let want = Preprocess.referenceResize(image, width: ow, height: oh, filter: filter)
                        #expect(got.bytes == want.bytes, "\(w)x\(h)x\(image.channels) -> \(ow)x\(oh) \(filter)")
                    }
                }
            }
        }
    }

    @Test func rejectsMismatchedPixelBuffers() {
        #expect(throws: EyeError.self) { try ImagePixels(width: 2, height: 2, rgba: [0, 0, 0]) }
        #expect(throws: EyeError.self) { try ImagePixels(width: 0, height: 2, rgb: []) }
        #expect((try? ImagePixels(width: 1, height: 1, rgb: [1, 2, 3])) != nil)
    }

    /// Pets: a weaker box mostly inside a stronger one of the same label goes; a
    /// box of another label, or one at least half as confident, stays.
    @Test func nmsDropsContainedWeakerBoxes() {
        func c(_ label: Int, _ conf: Double, _ b: [Double]) -> Decode.Candidate {
            .init(label: label, confidence: conf, x0: b[0], y0: b[1], x1: b[2], y1: b[3])
        }
        let kept = Decode.nms([
            c(0, 0.9, [0, 0, 1, 1]), c(0, 0.3, [0.1, 0.1, 0.4, 0.4]), c(0, 0.6, [0.5, 0.5, 0.8, 0.8]),
            c(1, 0.2, [0.1, 0.1, 0.4, 0.4]), c(0, 0.85, [0.02, 0, 1, 1]),
        ], iou: 0.3, contain: 0.6)
        #expect(kept.map(\.confidence) == [0.9, 0.6, 0.2])
    }

    @Test func softmaxIsStable() {
        let p = Decode.softmax([1000, 1000, -1000])
        #expect(abs(p[0] - 0.5) < 1e-12 && abs(p[1] - 0.5) < 1e-12 && p[2] < 1e-12)
    }

    // MARK: end to end through the model

#if !os(WASI)
    @Suite(.serialized, .modelBacked)
    struct ModelTests {
        /// The shipped Core ML (Apple) or LiteRT (elsewhere) model against the
        /// LiteRT reference: probabilities agree to this.
        static let tolerance = 0.08

        @Test func fixtureMatchesReference() async throws {
            let golden = try Golden.load()
            let want = golden.fixture.analysis
            let analysis = try await makeEye().analyze(try EyeTests.fixture(golden))
            let details = try #require(analysis.details)

            // Tags: the same decision at 0.5 and 0.9, unless either side is within 0.1 of the cutoff.
            #expect(Set(analysis.confidences.keys.map(\.rawValue)) == Set(want.tags.tags.keys))
            for (key, w) in want.tags.tags {
                let g = analysis.confidence(Tag(key)) ?? .nan
                for cut in [0.5, 0.9] where (g >= cut) != (w >= cut) {
                    #expect(abs(g - cut) <= 0.1 || abs(w - cut) <= 0.1, "tag \(key): \(g) vs \(w)")
                }
            }
            let computed = Set(analysis.confidences.keys).union((analysis.faces ?? []).flatMap(\.confidences.keys))
            #expect(Set(computed.map(\.rawValue)) == Tag.known, "Tags.swift is current: node Tools/eye-tags.mjs <eye_meta.json>")
            #expect(analysis.kind != nil && analysis.scores != nil && analysis.embedding?.count == 512 && analysis.crops?.isEmpty == false)

            let photo = try #require(details.photo)
            let dot = zip(photo.embedding, want.photo.embedding).map { Double($0) * Double($1) }.reduce(0, +)
            #expect(dot > 0.98, "embedding cosine \(dot)")
            for (name, got, ref) in [("type", photo.type, want.photo.type), ("reject", photo.reject, want.photo.reject),
                                     ("sensitive", photo.sensitive, want.photo.sensitive), ("scenes", photo.scenes, want.photo.scenes),
                                     ("blur", photo.blur, want.photo.blur), ("pet", photo.pet, want.photo.pet), ("peak", photo.peak, want.photo.peak)] {
                expectClose(got, ref, Self.tolerance, name)
            }
            expectClose(photo.aestheticAttributes, want.photo.aestheticAttributes, 0.3, "aesthetic attributes")
            expectClose(Dictionary(uniqueKeysWithValues: photo.rotation.map { (String($0.key), $0.value) }), want.photo.rotation,
                        Self.tolerance, "rotation")
            for (name, got, ref) in [("aesthetic", photo.aesthetic, want.photo.aesthetic), ("keeper", photo.keeper, want.photo.keeper),
                                     ("cover", photo.cover, want.photo.cover)] {
                #expect(abs(got - ref) < Self.tolerance, "\(name) \(got) vs \(ref)")
            }

            let layout = try #require(details.layout)
            let attention = correlation(layout.attention.values.map(Double.init), want.layout.attention)
            #expect(attention > 0.95, "attention correlation \(attention)")
            let crops = correlation(layout.crops.map(\.score), want.layout.crops)
            // Core ML on the CPU (no Neural Engine, as on CI) drifts most here: 0.89 on this photo.
            #expect(crops > 0.85, "crop score correlation \(crops)")
            expectClose(layout.shot, want.layout.shot, Self.tolerance, "shot")
            expectSameDetections(layout.people, want.layout.people, threshold: 0.25, "people")
            expectSameDetections(layout.pets, want.layout.pets, threshold: 0.15, "pets")

            let faces = try #require(details.faces)
            #expect(faces.count == want.faces.count, "faces \(faces.count) vs \(want.faces.count)")
            for ref in want.faces {
                guard let got = faces.max(by: { iou($0.box, ref.box) < iou($1.box, ref.box) }), iou(got.box, ref.box) > 0.7 else {
                    Issue.record("no face matches \(ref.box)")
                    continue
                }
                for (name, g, w) in [("eyesOpen", got.eyesOpen, ref.eyesOpen), ("smile", got.smile, ref.smile),
                                     ("looking", got.looking, ref.looking), ("quality", got.quality, ref.quality),
                                     ("isReal", got.isReal, ref.isReal), ("keepsake", got.keepsake, ref.keepsake)] {
                    #expect(abs(g - w) < 0.1, "face \(name) \(g) vs \(w)")
                }
                expectClose(got.expression, ref.expression, 0.1, "expression")
                #expect(abs(got.pose.yaw - ref.pose.yaw) < 10 && abs(got.pose.pitch - ref.pose.pitch) < 10, "pose \(got.pose) vs \(ref.pose)")
                #expect(got.landmarks.count == 5)
            }

            let sharpness = try #require(details.sharpness)
            #expect(abs(sharpness.score - want.sharpness.score) < 0.05)
            #expect(correlation(sharpness.blurMap.values.map(Double.init), want.sharpness.blurMap) > 0.95)
        }

        @Test func partsLimitTheWork() async throws {
            let golden = try Golden.load()
            let analysis = try await makeEye().analyze(try EyeTests.fixture(golden), options: .init(parts: .sharpness))
            let details = try #require(analysis.details)
            #expect(details.photo == nil && details.layout == nil && details.faces == nil && details.sharpness != nil)
            #expect(analysis.kind == nil && analysis.embedding == nil && analysis.faces == nil)
            #expect(analysis.confidence(.blurry) == nil, "blurry needs faces and the photo part too")
            #expect(analysis.confidence(.dog) == nil)
        }

        private func makeEye() -> Eye {
            if let dir = ProcessInfo.processInfo.environment["EYE_MODEL_DIR"] { return Eye(directory: dir) }
            return Eye()
        }

        private func expectClose(_ got: [String: Double], _ want: [String: Double], _ tolerance: Double, _ name: String,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(Set(got.keys) == Set(want.keys), "\(name) names", sourceLocation: sourceLocation)
            let worst = want.map { abs((got[$0.key] ?? .nan) - $0.value) }.max() ?? 0
            #expect(worst < tolerance, "\(name): worst difference \(worst)", sourceLocation: sourceLocation)
        }

        /// Detections clear of the threshold appear on both sides; one within 0.05
        /// of it may legitimately fall either way between runtimes. Boxes match at
        /// IoU 0.6: on the fixture's half-hidden third person, Core ML and LiteRT
        /// peak in neighbouring cells (IoU 0.69, ml-eye's decoder agrees with this one).
        private func expectSameDetections(_ got: [Detection], _ want: [Golden.Detection], threshold: Double, _ name: String) {
            for ref in want where ref.confidence > threshold + 0.05 {
                #expect(got.contains { $0.label == ref.label && iou($0.box, ref.box) > 0.6 }, "\(name): missing \(ref.label) \(ref.box)")
            }
            for d in got where d.confidence > threshold + 0.05 {
                #expect(want.contains { $0.label == d.label && iou(d.box, $0.box) > 0.6 }, "\(name): extra \(d.label) \(d.box)")
            }
        }

        private func iou(_ a: Box, _ b: [Double]) -> Double {
            let ix = max(0, min(a.x1, b[2]) - max(a.x0, b[0])), iy = max(0, min(a.y1, b[3]) - max(a.y0, b[1]))
            let inter = ix * iy, union = a.width * a.height + (b[2] - b[0]) * (b[3] - b[1]) - inter
            return union > 0 ? inter / union : 0
        }

        private func correlation(_ a: [Double], _ b: [Double]) -> Double {
            guard a.count == b.count, !a.isEmpty else { return 0 }
            let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
            var ab = 0.0, aa = 0.0, bb = 0.0
            for (x, y) in zip(a, b) { ab += (x - ma) * (y - mb); aa += (x - ma) * (x - ma); bb += (y - mb) * (y - mb) }
            return ab / (aa * bb).squareRoot()
        }
    }

    static func fixture(_ golden: Golden) throws -> ImagePixels {
        let url = try #require(Bundle.module.url(forResource: "eye_fixture", withExtension: "gray"))
        let gray = [UInt8](try Data(contentsOf: url))
        return try ImagePixels(width: golden.fixture.width, height: golden.fixture.height, rgb: gray.flatMap { [$0, $0, $0] })
    }
#endif

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

    static func fnv1a(_ bytes: [UInt8]) -> UInt32 {
        var h: UInt32 = 0x811C_9DC5
        for b in bytes { h = (h ^ UInt32(b)) &* 0x0100_0193 }
        return h
    }
}

#if !os(WASI)
struct Golden: Decodable {
    struct Inputs: Decodable {
        let width, height: Int
        let centre, squash, letterbox, face, sharp: UInt32
        let faceBox: [Double]
        let sharpFunction: String

        enum CodingKeys: String, CodingKey {
            case width, height, centre, squash, letterbox, face, sharp
            case faceBox = "face_box", sharpFunction = "sharp_function"
        }
    }

    struct Photo: Decodable {
        let embedding: [Float]
        let type, reject, sensitive, scenes, rotation, aestheticAttributes, blur, pet, peak: [String: Double]
        let aesthetic, keeper, cover, bokeh: Double
    }

    struct Detection: Decodable {
        let label: String
        let confidence: Double
        let box: [Double]
    }

    struct Layout: Decodable {
        let attention: [Double]
        let people, pets: [Detection]
        let shot: [String: Double]
        let crops: [Double]
    }

    struct Pose: Decodable { let yaw, pitch, roll: Double }

    struct Face: Decodable {
        let box: [Double]
        let confidence, isFace, isReal, eyesOpen, smile, looking, sharp, keepsake, quality: Double
        let blink, mouth, expression, occlusion, lighting: [String: Double]
        let landmarks: [[Double]]
        let pose: Pose
    }

    struct Sharpness: Decodable {
        let score: Double
        let blurMap: [Double]
    }

    struct Tags: Decodable {
        let tags: [String: Double]
        let faces: [[String: Double]]
    }

    struct Analysis: Decodable {
        let photo: Photo
        let layout: Layout
        let faces: [Face]
        let sharpness: Sharpness
        let tags: Tags
    }

    struct Fixture: Decodable {
        let width, height: Int
        let analysis: Analysis
    }

    let preprocess: [Inputs]
    let fixture: Fixture

    static func load() throws -> Golden {
        let url = try #require(Bundle.module.url(forResource: "eye_golden", withExtension: "json"))
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }
}
#endif
