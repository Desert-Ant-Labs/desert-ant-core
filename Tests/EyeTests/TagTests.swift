#if !os(WASI)
import Foundation
import JSON
import Testing
@testable import Eye

/// Tags, scores and the across-photo helpers, without the model.
struct TagTests {
    /// ml-eye's `ml_eye.tags.evaluate` on synthetic inputs (eye_tag_cases.json,
    /// written by its scripts/sdk_goldens.py from the pinned model's tags):
    /// the SDK's evaluation must give the same confidence for every tag.
    @Test func tagsMatchTheReferenceEvaluator() throws {
        let url = try #require(Bundle.module.url(forResource: "eye_tag_cases", withExtension: "json"))
        let file = try JSONDecoder().decode(Cases.self, from: [UInt8](try Data(contentsOf: url)))
        #expect(file.cases.count >= 50)
        for (n, c) in file.cases.enumerated() {
            let faces = c.faces?.map { f in
                TagSpec.FaceInput(box: Box(x0: f.box[0], y0: f.box[1], x1: f.box[2], y1: f.box[3]), confidence: f.confidence,
                                  isReal: f.is_real, signals: ["eyes_open": f.eyes_open, "smile": f.smile, "looking": f.looking,
                                                               "quality": f.quality]
                                      .merging(f.expression.map { ("expression.\($0.key)", $0.value) }) { a, _ in a })
            }
            let got = file.spec.evaluate(outputs: c.outputs?.mapValues { $0.map(Float.init) }, sharpness: c.sharpness, faces: faces,
                                         width: c.width, height: c.height)
            #expect(Set(got.photo.keys) == Set(c.expect.tags.keys), "case \(n): tags computed")
            // Float32 outputs in the SDK, float64 in Python: allow for the rounding.
            let worst = c.expect.tags.map { abs((got.photo[$0.key] ?? .nan) - $0.value) }.max() ?? 0
            #expect(worst < 1e-4, "case \(n): worst difference \(worst)")
            #expect(got.faces?.count == c.expect.faces?.count, "case \(n): faces")
            for (g, w) in zip(got.faces ?? [], c.expect.faces ?? []) {
                #expect(w.allSatisfy { abs((g[$0.key] ?? .nan) - $0.value) < 1e-4 }, "case \(n): face tags")
            }
        }
    }

    @Test func levelsAreTheSameForEveryTag() {
        let a = Self.analysis(tags: ["dog": 0.55, "beach": 0.95, "blurry": 0.2])
        #expect(a.has(.dog) && !a.has(.dog, .strict))
        #expect(a.has(.beach, .strict))
        #expect(!a.has(.blurry) && !a.has(.cat))
        #expect(a.tags() == [.beach, .dog])
        #expect(a.tags(.strict) == [.beach])
        #expect(a.confidence(.cat) == nil)
    }

    @Test func analysesRoundTripThroughJSON() throws {
        let a = Self.analysis(tags: ["dog": 0.7, "group_shot": 1], embedding: [0.6, 0.8])
        let json = try JSONEncoder().encodeToString(a)
        let b = try JSONDecoder().decode(Analysis.self, from: json)
        #expect(b.confidences == a.confidences && b.model == a.model && b.kind == a.kind && b.rotation == a.rotation)
        #expect(b.embedding == a.embedding && b.scores == a.scores && b.crops == a.crops && b.people == a.people)
        #expect(b.faces?.first?.confidences == a.faces?.first?.confidences)
        #expect(b.details == nil && b.duplicates == a.duplicates)
        #expect(json.contains("\"tags\":{") && json.contains("\"group_shot\""), "tags keyed by id")
    }

    @Test func duplicatesGroupSimilarPhotosTakenCloseTogether() {
        let near = Self.analysis(tags: [:], embedding: [1, 0], keeper: 0.2)
        let nearer = Self.analysis(tags: [:], embedding: [0.99, 0.141], keeper: 0.9)
        let other = Self.analysis(tags: [:], embedding: [0, 1])
        let photos = [near, other, nearer]
        #expect(Eye.duplicates(in: photos) == [[2, 0]], "the better keeper first")
        #expect(Eye.duplicates(in: photos, dates: [0, 5, 10]) == [[2, 0]])
        #expect(Eye.duplicates(in: photos, dates: [0, 5, 3600]).isEmpty, "an hour apart is not a duplicate")
        #expect(Eye.best(of: photos) == 2)
        #expect(Eye.best(of: []) == nil)
        let blink = Self.analysis(tags: ["eyes_closed": 0.8], embedding: [1, 0], keeper: 0.99)
        #expect(Eye.best(of: [blink, near]) == 1, "closed eyes lose to a lower keeper score")
        #expect(Eye.similar(to: near, in: photos, limit: 2).map(\.index) == [0, 2])
    }

    @Test func bestCropKeepsTheAspectAndStaysInside() throws {
        let a = Self.analysis(tags: [:], crops: [Crop(box: Box(x0: 0.1, y0: 0.1, x1: 0.6, y1: 0.9), score: 2),
                                                  Crop(box: Box(x0: 0, y0: 0, x1: 1, y1: 0.75), score: 1)], width: 1000, height: 750)
        let square = try #require(a.bestCrop(aspect: 1))
        #expect(abs(square.width * 1000 / (square.height * 750) - 1) < 0.11)
        let banner = try #require(a.bestCrop(aspect: 3))
        #expect(abs(banner.width * 1000 / (banner.height * 750) - 3) < 1e-9)
        #expect(banner.x0 >= 0 && banner.y0 >= 0 && banner.x1 <= 1 && banner.y1 <= 1)
    }

    static func analysis(tags: [String: Double], embedding: [Float]? = nil, keeper: Double = 0.5, crops: [Crop]? = nil,
                         width: Int = 4032, height: Int = 3024) -> Analysis {
        let face = Face(box: Box(x0: 0.4, y0: 0.3, x1: 0.5, y1: 0.45), detectionConfidence: 0.9, landmarks: [Point(x: 0.43, y: 0.35)],
                        pose: Pose(yaw: 3, pitch: -2, roll: 1), quality: 0.7, confidences: [.smiling: 0.8])
        return Analysis(model: "eye@test", width: width, height: height, confidences: tagged(tags), kind: .photo,
                        scores: Scores(aesthetic: 0.6, keeper: keeper, cover: 0.4), rotation: nil, embedding: embedding,
                        people: [Detection(label: "person", confidence: 0.8, box: Box(x0: 0.3, y0: 0.2, x1: 0.6, y1: 0.9))],
                        pets: [], faces: [face], crops: crops, details: nil,
                        duplicates: DuplicateRule(similarity: 0.9, windowSeconds: 29, windowSecondsPeople: 17))
    }

    struct Cases: Decodable {
        let spec: TagSpec
        let cases: [Case]
    }

    struct Case: Decodable {
        let width: Int
        let height: Int
        let outputs: [String: [Double]]?
        let sharpness: Double?
        let faces: [CaseFace]?
        let expect: Expect
    }

    struct CaseFace: Decodable {
        let box: [Double]
        let confidence: Double
        let is_real: Double
        let eyes_open: Double
        let smile: Double
        let looking: Double
        let quality: Double
        let expression: [String: Double]
    }

    struct Expect: Decodable {
        let tags: [String: Double]
        let faces: [[String: Double]]?
    }
}
#endif
