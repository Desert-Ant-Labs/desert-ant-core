import Foundation
import Testing
#if canImport(AVFoundation)
import AVFoundation
import ImageIO
#endif
import DesertAnt
import TestSupport
@testable import Face
@testable import FaceCore

struct FaceTests {
#if !os(WASI)
    @Test func alignmentMatchesTheReferenceTransform() throws {
        let golden = try Golden.load()
        for (_, photo) in golden.photos {
            for f in photo.faces {
                let m = Align.transform(f.landmarks.map { ($0[0], $0[1]) })
                let want = f.matrix
                for (got, ref) in [(m.a, want[0][0]), (m.c, want[0][1]), (m.tx, want[0][2]),
                                   (m.b, want[1][0]), (m.d, want[1][1]), (m.ty, want[1][2])] {
                    #expect(abs(got - ref) < 1e-6, "transform \(got) vs \(ref)")
                }
            }
        }
    }

    @Test func alignedCropMatchesOpenCV() throws {
        let golden = try Golden.load()
        let face = try #require(golden.photos["single_a1.png"]?.faces.first)
        let rgb = Preprocess.rgb(try Self.photo("single_a1"))
        let crop = Align.crop(rgb, landmarks: face.landmarks.map { ($0[0], $0[1]) })
        let want = Preprocess.rgb(try Self.photo("aligned_a1"))
        #expect(crop.width == 128 && crop.height == 128 && want.width == 128)
        let diffs = zip(crop.bytes, want.bytes).map { abs(Int($0) - Int($1)) }
        let mean = Double(diffs.reduce(0, +)) / Double(diffs.count)
        #expect(mean < 1.0, "mean abs difference \(mean)")
        #expect((diffs.max() ?? 0) <= 8, "max abs difference \(diffs.max() ?? 0)")
    }
#endif

    @Test func decodeFindsAPeakAndItsLandmarks() {
        let h = 8, w = 8, n = h * w
        var heat = [Float](repeating: -10, count: n)
        heat[3 * w + 5] = 2
        heat[3 * w + 4] = 1
        var size = [Float](repeating: 0, count: 2 * n)
        size[3 * w + 5] = Float(log(10.0 / 4))
        size[n + 3 * w + 5] = Float(log(12.0 / 4))
        let offset = [Float](repeating: 0.5, count: 2 * n)
        var lm = [Float](repeating: 0, count: 10 * n)
        lm[0 * n + 3 * w + 5] = -0.25
        let faces = Decode.faces(heatmap: heat, size: size, offset: offset, landmarks: lm, h: h, w: w)
        #expect(faces.count == 1)
        let f = faces[0]
        #expect(abs(f.confidence - 1 / (1 + exp(-2.0))) < 1e-9)
        #expect(abs((f.x0 + f.x1) / 2 - 22) < 1e-9 && abs((f.y0 + f.y1) / 2 - 14) < 1e-9)
        #expect(abs(f.x1 - f.x0 - 10) < 1e-6 && abs(f.y1 - f.y0 - 12) < 1e-6)
        #expect(abs(f.landmarks[0].0 - (22 - 2.5)) < 1e-6)
    }

    @Test func nmsKeepsTheStrongerOfTwoOverlappingFaces() {
        let a = Decode.Candidate(confidence: 0.9, x0: 0, y0: 0, x1: 10, y1: 10, landmarks: [])
        let b = Decode.Candidate(confidence: 0.6, x0: 1, y0: 1, x1: 11, y1: 11, landmarks: [])
        let c = Decode.Candidate(confidence: 0.5, x0: 20, y0: 20, x1: 30, y1: 30, landmarks: [])
        let kept = Decode.nms([b, c, a])
        #expect(kept.map(\.confidence) == [0.9, 0.5])
    }

    @Test func letterboxScalesTheLongSideTo768() {
        let image = Preprocess.Plane(width: 400, height: 200, channels: 3, bytes: [UInt8](repeating: 200, count: 400 * 200 * 3))
        let (frame, scale) = Preprocess.letterbox(image)
        #expect(frame.width == 768 && frame.height == 768 && scale == 768.0 / 400)
        #expect(frame.bytes[(100 * 768 + 100) * 3] == 200)
        #expect(frame.bytes[(600 * 768 + 100) * 3] == 114)
    }

    @Test func faceprintsAreUnitLengthAndCompareByCosine() throws {
        let a = Faceprint(values: [3, 4] + [Float](repeating: 0, count: 126))
        #expect(abs(a.values.reduce(0) { $0 + $1 * $1 } - 1) < 1e-6)
        let b = Faceprint(values: [4, 3] + [Float](repeating: 0, count: 126))
        #expect(abs(a.similarity(to: b) - 0.96) < 1e-6)
        #expect(a.isSamePerson(as: b) && a.isSamePerson(as: b, .strict))
        let c = Faceprint(values: [0, 0, 1] + [Float](repeating: 0, count: 125))
        #expect(!a.isSamePerson(as: c))
        let other = Faceprint(values: b.values, model: "face-0")
        #expect(!a.isSamePerson(as: other), "faceprints of different models never match")
        let short = Faceprint(values: Array(a.values.prefix(64)))
        #expect(a.similarity(to: short) == 0 && short.similarity(to: a) == 0, "faceprints of different lengths never compare")
        #expect(!a.isSamePerson(as: short) && !short.isSamePerson(as: a) && !a.isComparable(to: short))
        #expect(Face.matches(for: a, in: [short, b]).map(\.index) == [1] && Face.matches(for: short, in: [a]).isEmpty)
        let round = try Foundation.JSONDecoder().decode(Faceprint.self, from: Foundation.JSONEncoder().encode(a))
        #expect(round == a)
        let mean = try #require(Faceprint(averaging: [a, b]))
        #expect(abs(mean.similarity(to: a) - mean.similarity(to: b)) < 1e-6)
        #expect(Faceprint(averaging: []) == nil && Faceprint(averaging: [a, other]) == nil)
        #expect(Faceprint.Level.recommended.cutoff < Faceprint.Level.strict.cutoff)
    }

    @Test func matchesRankAboveTheCutoff() {
        let ref = Self.unit(0)
        let library = [Self.mix(0, 1, 0.9), Self.unit(1), Self.mix(0, 1, 0.6), Self.mix(0, 2, 0.45)]
        let found = Face.matches(for: ref, in: library)
        #expect(found.map(\.index) == [0, 2, 3])
        #expect(found.map(\.similarity) == found.map(\.similarity).sorted(by: >))
        #expect(Face.matches(for: ref, in: library, level: .strict).map(\.index) == [0, 2])
    }

    /// Two groups close enough for the second pass stay apart when they share one photo, however many photos each has.
    @Test func groupsThatShareAPhotoNeverMerge() {
        let a = Self.unit(0), b = Self.mix(0, 1, 0.6)
        let faces = [Faceprint](repeating: a, count: 50) + [Faceprint](repeating: b, count: 50)
        let shared = (0..<50).map { "a\($0)" } + ["a49"] + (1..<50).map { "b\($0)" }
        #expect(Self.groups(faces, photos: shared).count == 2)
        let apart = (0..<50).map { "a\($0)" } + (0..<50).map { "b\($0)" }
        #expect(Self.groups(faces, photos: apart).count == 1, "without the shared photo they are one person")
    }

    @Test func groupingKeepsEachPersonAndAPhotosFacesApart() {
        var faces: [Faceprint] = [], photos: [String] = []
        var rng = SplitMix(seed: 7)
        for person in 0..<3 {
            for k in 0..<5 {
                faces.append(Self.noisy(person, &rng, 0.35))
                photos.append("p\(person)-\(k)")
            }
        }
        faces.append(Self.noisy(0, &rng, 0.35))
        photos.append("group")
        faces.append(Self.noisy(1, &rng, 0.35))
        photos.append("group")
        let people = FaceTests.groups(faces, photos: photos)
        #expect(people.count == 3)
        #expect(people.map(\.count) == [6, 6, 5])
        let person = (0..<15).map { $0 / 5 } + [0, 1]
        for g in people { #expect(Set(g.map { person[$0] }).count == 1, "one person per group") }
        #expect(!people.contains { $0.contains(15) && $0.contains(16) })

        let same = FaceTests.groups([faces[0], faces[0]], photos: ["x", "x"])
        #expect(same.count == 2)
        #expect(FaceTests.groups([Faceprint](), photos: [String]()).isEmpty)
    }

    @Test func groupingJoinsTwoLooksOfOnePerson() {
        var faces: [Faceprint] = [], photos: [Int] = []
        var rng = SplitMix(seed: 11)
        for k in 0..<40 {
            let look = k < 20 ? 1 : 2
            var v = [Float](repeating: 0, count: 128)
            v[0] = 0.8
            v[look] = 0.45
            for i in 3..<128 { v[i] = Float(rng.gaussian()) * 0.07 }
            faces.append(Faceprint(values: v))
            photos.append(k)
        }
        var g = Cluster.Groups(faces.map(\.values), photos: photos.map(Int32.init), seeds: (0..<40).map { Cluster.Seed(faces: [$0]) })
        g.run(threshold: Cluster.firstPass, means: false)
        let first = (0..<40).map { g.root($0) }
        #expect(Set(first).count == 2)
        #expect(FaceTests.groups(faces, photos: photos).count == 1)
    }

    @Test func groupingScalesToALibrary() {
        var faces: [Faceprint] = [], photos: [Int] = []
        var rng = SplitMix(seed: 3)
        for person in 0..<(FaceTests.scaleTestFaces / 5) {
            for _ in 0..<5 {
                faces.append(Self.noisy(person % 128, &rng, 0.3, salt: person))
                photos.append(faces.count)
            }
        }
        let start = Date()
        let people = FaceTests.groups(faces, photos: photos)
        #expect(Date().timeIntervalSince(start) < 60, "\(FaceTests.scaleTestFaces) faces took \(Date().timeIntervalSince(start)) s")
        #expect(people.reduce(0) { $0 + $1.count } == FaceTests.scaleTestFaces)
    }

    @Test func portableGroupingMatchesAccelerate() {
        var faces: [Faceprint] = [], photos: [Int] = []
        var rng = SplitMix(seed: 5)
        for person in 0..<(FaceTests.scaleTestFaces / 10) {
            for _ in 0..<5 {
                faces.append(Self.noisy(person % 128, &rng, 0.3, salt: person))
                photos.append(faces.count)
            }
        }
        var a = [Float](repeating: 0, count: 300 * 300), b = a
        let x = faces.prefix(300).flatMap(\.values)
        Cluster.gemmPortable(x, r0: 0, rows: 300, m: 300, d: 128, into: &a)
        for r in 0..<300 { for j in 0..<300 { b[r * 300 + j] = zip(x[(r * 128)..<(r * 128 + 128)], x[(j * 128)..<(j * 128 + 128)]).reduce(0) { $0 + $1.0 * $1.1 } } }
        #expect(zip(a, b).allSatisfy { abs($0 - $1) < 1e-4 })

        let t0 = Date()
        let fast = Self.groups(faces, photos: photos)
        let t1 = Date()
        let portable = Cluster.$portable.withValue(true) { Self.groups(faces, photos: photos) }
        let t2 = Date()
        print("Grouping \(faces.count) faces: \(String(format: "%.2f", t1.timeIntervalSince(t0))) s with Accelerate, \(String(format: "%.2f", t2.timeIntervalSince(t1))) s portable")
        #expect(Set(fast.map(Set.init)) == Set(portable.map(Set.init)))
    }

    @Test func rejectsMismatchedPixelBuffers() {
        #expect(throws: FaceError.self) { try ImagePixels(width: 2, height: 2, rgba: [0, 0, 0]) }
        #expect(throws: FaceError.self) { try ImagePixels(width: 0, height: 2, rgb: []) }
        #expect((try? ImagePixels(width: 1, height: 1, rgb: [1, 2, 3])) != nil)
    }

    @Test func optionsDefaults() {
        let o = FaceDetector.Options()
        #expect(o.minimumConfidence == 0.3 && o.minimumSize == 32 && o.maxFaces == 20)
        #expect(Face.Options.recognition == FaceDetector.Options(minimumConfidence: 0.35))
        #expect(Face.modelRepo == "desert-ant-labs/face" && Face.modelRevision == FaceModel.revision)
    }

    @Test func theDetectorDownloadsAlone() {
        for platform in ModelPlatform.allCases {
            let detector = try! #require(FaceModel.detectorFiles.files[platform])
            let embedder = try! #require(FaceModel.embedderFiles.files[platform])
            #expect(detector.count == 1 && embedder.count == 1)
            #expect(FaceModel.files[platform] == detector + embedder)
            #expect(detector[0].hasPrefix("face_detect.") && FaceModel.artifact(for: platform).hasPrefix("face_detect."))
        }
        #expect(FaceModel.detectorFiles.repo == FaceModel.repo && FaceModel.detectorFiles.revision == FaceModel.revision)
    }

#if !os(WASI)
    @Suite(.serialized, .modelBacked)
    struct ModelTests {
        @Test func photosMatchTheReferencePipeline() async throws {
            let golden = try Golden.load()
            let face = FaceTests.makeFace()
            for (name, want) in golden.photos.sorted(by: { $0.key < $1.key }) {
                let got = try await face.faces(in: try FaceTests.photo(String(name.dropLast(4))))
                #expect(got.count == want.faces.count, "\(name): \(got.count) faces, expected \(want.faces.count)")
                for (g, w) in zip(got, want.faces) {
                    let W = Double(want.width), H = Double(want.height)
                    let box = Box(x0: w.box[0] / W, y0: w.box[1] / H, x1: w.box[2] / W, y1: w.box[3] / H)
                    #expect(FaceTests.iou(g.box, box) > 0.9, "\(name) box")
                    #expect(abs(g.confidence - w.score) < 0.05, "\(name) confidence \(g.confidence) vs \(w.score)")
                    for (p, q) in zip(g.landmarks, w.landmarks) {
                        #expect(abs(p.x - q[0] / W) < 0.01 && abs(p.y - q[1] / H) < 0.01, "\(name) landmark")
                    }
                    let cos = g.faceprint.similarity(to: Faceprint(values: w.embedding.map(Float.init)))
                    #expect(cos > 0.98, "\(name) faceprint cosine to the reference \(cos)")
                }
            }
        }

        @Test func useCases() async throws {
            let face = FaceTests.makeFace()
            let a1 = try #require(try await face.faces(in: try FaceTests.photo("single_a1")).first)
            let a2 = try #require(try await face.faces(in: try FaceTests.photo("single_a2")).first)
            let b1 = try #require(try await face.faces(in: try FaceTests.photo("single_b1")).first)
            let group = try await face.faces(in: try FaceTests.photo("group"))
            #expect(try await face.faces(in: try FaceTests.photo("empty")).isEmpty)

            #expect(a1.faceprint.isSamePerson(as: a2.faceprint, .strict))
            #expect(!a1.faceprint.isSamePerson(as: b1.faceprint))
            #expect(group.count == 2)

            let library = [a2, b1] + group
            let hits = Face.matches(for: a1.faceprint, in: library.map(\.faceprint))
            #expect(Set(hits.map(\.index)) == [0, 2] || Set(hits.map(\.index)) == [0, 3])
            let left = group.min { $0.box.x0 < $1.box.x0 }!
            #expect(left.faceprint.isSamePerson(as: a1.faceprint), "the left face of the group photo is A")

            let ref = try #require(Faceprint(averaging: [a1.faceprint, a2.faceprint]))
            #expect(Set(Face.matches(for: ref, in: library.map(\.faceprint)).map(\.index)) == Set(hits.map(\.index)))

            let all = [a1, a2, b1] + group
            let photos = ["a1", "a2", "b1", "group", "group"]
            let people = FaceTests.groups(all.map(\.faceprint), photos: photos)
            #expect(people.count == 2, "\(people)")
            let gi = all.firstIndex { $0 == left }!
            let aGroup = try #require(people.first { $0.contains(0) })
            #expect(Set(aGroup) == [0, 1, gi])
        }

        @Test func sidewaysFacesMatchUpright() async throws {
            let face = FaceTests.makeFace()
            for name in ["single_a1", "group"] {
                let image = try FaceTests.photo(name)
                let upright = try await face.faces(in: image)
                for quarterTurns in 1...3 {
                    let turned = try await face.faces(in: try FaceTests.turned(image, quarterTurns))
                    #expect(turned.count == upright.count, "\(name) \(quarterTurns * 90): \(turned.count) faces")
                    for t in turned {
                        let best = upright.map { $0.faceprint.similarity(to: t.faceprint) }.max() ?? -1
                        #expect(best > 0.9, "\(name) \(quarterTurns * 90): cosine to upright \(best)")
                    }
                }
            }
        }

        @Test func theDetectorFindsWhatFaceFinds() async throws {
            let face = FaceTests.makeFace()
            let detector = FaceTests.makeDetector()
            for name in ["single_a1", "group", "empty"] {
                let image = try FaceTests.photo(name)
                #expect(try await detector.faces(in: image, options: .recognition)
                        == (try await face.faces(in: image)).map(\.detection), "\(name)")
            }
        }

        @Test func optionsFilterTheFaces() async throws {
            let face = FaceTests.makeFace()
            let image = try FaceTests.photo("group")
            #expect(try await face.faces(in: image, options: .init(maxFaces: 1)).count == 1)
            #expect(try await face.faces(in: image, options: .init(minimumConfidence: 0.99)).isEmpty)
            #expect(try await face.faces(in: image, options: .init(minimumSize: 400)).isEmpty)
        }

#if canImport(ImageIO)
        @Test func filesAndDataAndCGImageAgree() async throws {
            let face = FaceTests.makeFace()
            let url = try #require(Bundle.module.url(forResource: "single_a1", withExtension: "png"))
            let fromURL = try await face.faces(contentsOf: url)
            let fromData = try await face.faces(data: try Data(contentsOf: url))
            #expect(fromURL.count == 1 && fromURL == fromData)
        }
#endif

        @Test func aPopulatedDirectoryLoadsWithoutTheCache() async throws {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("face-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            try await ModelFixture.populate(FaceModel.self, into: dir)
            let face = Face(directory: dir.path)
            #expect(face.isDownloaded())
            #expect(try await face.faces(in: try FaceTests.photo("single_b1")).count == 1)
        }

        @Test func cancellationStopsPromptly() async throws {
            let face = FaceTests.makeFace()
            try await face.download()
            let task = Task { try await face.faces(in: try FaceTests.photo("group")) }
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        }

        @Test func aLibraryOfRealPhotos() async throws {
            let face = FaceTests.makeFace()
            var library = FaceLibrary()
            for name in ["single_a1", "single_a2", "single_b1", "group", "empty"] {
                library.add(try await face.faces(in: try FaceTests.photo(name)), photo: name)
            }
            library.regroup()
            let people = library.people()
            #expect(people.map(\.photoCount) == [3, 2], "\(people)")
            let a = try #require(library.face("single_a1#0")?.person)
            #expect(library.face("single_a2#0")?.person == a)
            #expect(Set(people[0].faces.compactMap { library.face($0)?.photo }) == ["single_a1", "single_a2", "group"])
            let again = try #require(try await face.faces(in: try FaceTests.photo("single_a2")).first)
            #expect(library.person(for: again.faceprint)?.id == a)
            library.name(a, "A")
            let saved = try Foundation.JSONEncoder().encode(library)
            #expect(try Foundation.JSONDecoder().decode(FaceLibrary.self, from: saved).people(.prominent).map(\.name) == ["A"])
        }

#if canImport(AVFoundation)
        @Test func video() async throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("face-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: url) }
            try await FaceTests.writeVideo(to: url, photos: ["single_a1", "group"], secondsEach: 1)
            let face = FaceTests.makeFace()
            var frames: [VideoFrame] = []
            for try await frame in face.faces(inVideoAt: url, every: 0.5) { frames.append(frame) }
            #expect(frames.map(\.time) == [0, 0.5, 1, 1.5])
            #expect(frames.map(\.faces.count) == [1, 1, 2, 2])
            var library = FaceLibrary()
            for f in frames { library.add(f.faces, photo: f.photoID(in: "clip")) }
            library.regroup()
            #expect(library.people().map(\.photoCount) == [4, 2])
            #expect(frames[0].photoID(in: "clip") == "clip@0.000")
        }

        /// A frame is read and analyzed only when the reader asks for it: none run ahead of a slow reader.
        @Test func videoFramesWaitForTheReader() async throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("face-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: url) }
            try await FaceTests.writeVideo(to: url, photos: ["single_a1", "group"], secondsEach: 1)
            let analyzed = Analyzed()
            let stream = Face.frames(inVideoAt: url, every: 0.25) { _ in
                analyzed.add()
                return []
            }
            var frames = stream.makeAsyncIterator()
            _ = try await frames.next()
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(analyzed.count == 1, "one frame asked for, one analyzed")
            _ = try await frames.next()
            #expect(analyzed.count == 2)
            var rest = 0
            while try await frames.next() != nil { rest += 1 }
            #expect(rest == 6 && analyzed.count == 8)
        }
#endif

        @Test func throughputOnThisMachine() async throws {
            let face = FaceTests.makeFace()
            let image = try FaceTests.photo("group")
            _ = try await face.faces(in: image)
            let start = Date()
            for _ in 0..<10 { _ = try await face.faces(in: image) }
            let ms = Date().timeIntervalSince(start) * 100
            print("Face: \(String(format: "%.1f", ms)) ms per 900 x 420 photo with two faces")
#if canImport(CoreML)
            #expect(ms < 250)
#elseif !os(Windows)
            #expect(ms < 1000, "LiteRT on the CPU")
#endif
        }
    }
#endif

#if canImport(AVFoundation)
    static func writeVideo(to url: URL, photos: [String], secondsEach: Int) async throws {
        let w = 960, h = 540, fps: Int32 = 10
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var frame: Int64 = 0
        for name in photos {
            let file = try #require(Bundle.module.url(forResource: name, withExtension: "png"))
            let src = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
            for _ in 0..<(secondsEach * Int(fps)) {
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &buffer)
                let pb = try #require(buffer)
                CVPixelBufferLockBaseAddress(pb, [])
                let ctx = try #require(CGContext(
                    data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
                ctx.setFillColor(gray: 0, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.draw(image, in: CGRect(x: (w - image.width) / 2, y: (h - image.height) / 2,
                                           width: image.width, height: image.height))
                CVPixelBufferUnlockBaseAddress(pb, [])
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                adaptor.append(pb, withPresentationTime: CMTime(value: frame, timescale: fps))
                frame += 1
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
    }
#endif

    static func groups<Photo: Hashable>(_ faceprints: [Faceprint], photos: [Photo]) -> [[Int]] {
        var ids: [Photo: Int32] = [:]
        let photo = photos.map { p -> Int32 in
            if let i = ids[p] { return i }
            ids[p] = Int32(ids.count)
            return Int32(ids.count - 1)
        }
        var out: [Int: [Int]] = [:]
        for (i, l) in Cluster.group(faceprints.map(\.values), photos: photo).enumerated() { out[l, default: []].append(i) }
        return out.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0] }
    }

#if os(WASI) || os(Windows)
    static let scaleTestFaces = 2000
#elseif os(iOS) || os(Linux) || os(Android)
    // The shared Linux runners run other jobs beside this one: 20,000 faces took 72 to 125 s there.
    static let scaleTestFaces = 5000
#else
    static let scaleTestFaces = 20000
#endif

    static func makeFace() -> Face {
        if let dir = ProcessInfo.processInfo.environment["FACE_MODEL_DIR"] { return Face(directory: dir) }
        return Face()
    }

    static func makeDetector() -> FaceDetector {
        if let dir = ProcessInfo.processInfo.environment["FACE_MODEL_DIR"] { return FaceDetector(directory: dir) }
        return FaceDetector()
    }

    /// `image` turned clockwise by `quarterTurns` quarter turns.
    static func turned(_ image: ImagePixels, _ quarterTurns: Int) throws -> ImagePixels {
        var w = image.width, h = image.height, bytes = image.bytes
        let c = image.channels
        for _ in 0..<quarterTurns {
            var out = [UInt8](repeating: 0, count: bytes.count)
            for y in 0..<h {
                for x in 0..<w {
                    let s = (y * w + x) * c, d = (x * h + (h - 1 - y)) * c
                    for k in 0..<c { out[d + k] = bytes[s + k] }
                }
            }
            (w, h, bytes) = (h, w, out)
        }
        return try ImagePixels(width: w, height: h, channels: c, bytes: bytes)
    }

    static func photo(_ name: String) throws -> ImagePixels {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "rgb"))
        let bytes = [UInt8](try Data(contentsOf: url))
        let w = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        let h = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
        return try ImagePixels(width: w, height: h, rgb: Array(bytes[8...]))
    }

    static func iou(_ a: Box, _ b: Box) -> Double {
        let iw = max(0, min(a.x1, b.x1) - max(a.x0, b.x0)), ih = max(0, min(a.y1, b.y1) - max(a.y0, b.y0))
        let inter = iw * ih
        return inter / (a.width * a.height + b.width * b.height - inter)
    }

    static func unit(_ i: Int) -> Faceprint {
        var v = [Float](repeating: 0, count: 128)
        v[i] = 1
        return Faceprint(values: v)
    }

    static func mix(_ a: Int, _ b: Int, _ c: Float) -> Faceprint {
        var v = [Float](repeating: 0, count: 128)
        v[a] = c
        v[b] = (1 - c * c).squareRoot()
        return Faceprint(values: v)
    }

    static func noisy(_ person: Int, _ rng: inout SplitMix, _ noise: Double, salt: Int = 0) -> Faceprint {
        var v = [Float](repeating: 0, count: 128)
        v[person % 128] = 1
        if salt > 0 { v[(salt * 7 + 3) % 128] += 0.8 }
        for i in 0..<128 { v[i] += Float(rng.gaussian() * noise / Double(128).squareRoot()) }
        return Faceprint(values: v)
    }

    struct Golden: Decodable {
        struct Photo: Decodable {
            struct F: Decodable {
                let box: [Double]
                let score: Double
                let landmarks: [[Double]]
                let embedding: [Double]
                let matrix: [[Double]]
            }
            let width: Int
            let height: Int
            let faces: [F]
        }
        let photos: [String: Photo]

        static func load() throws -> Golden {
            let url = try #require(Bundle.module.url(forResource: "face_golden", withExtension: "json"))
            return try Foundation.JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
        }
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / 9_007_199_254_740_992 }
    mutating func gaussian() -> Double {
        let u = max(uniform(), 1e-12), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

private final class Analyzed: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func add() { lock.withLock { n += 1 } }
}
