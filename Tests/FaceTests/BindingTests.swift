import Foundation
import Testing
import DesertAnt
import TestSupport
@testable import FaceCore
import JSON
@testable @_spi(FaceBindings) import Face

struct BindingTests {
    struct Opened: Decodable { let handle: Int }
    struct Failed: Error { let op: String }

    static func raw(_ host: any BoundModel, _ op: String, _ args: String, image: ImagePixels? = nil) async -> String? {
        var input = FFIWriter()
        if let image {
            input.u32(image.width)
            input.u32(image.height)
            input.u32(image.channels)
            input.u32(image.bytes.count)
            input.raw(image.bytes)
        }
        var options = FFIWriter()
        options.string(op)
        options.string(args)
        guard let out = await host.run(input: FFIReader(input.bytes), options: FFIReader(options.bytes)) else { return nil }
        var reader = FFIReader(out)
        return reader.string()
    }

    static func call<T: Decodable>(_ host: any BoundModel, _ op: String, _ args: String = "{}", as type: T.Type,
                                   image: ImagePixels? = nil) async throws -> T {
        guard let text = await raw(host, op, args, image: image) else { throw Failed(op: op) }
        return try JSON.JSONDecoder().decode(type, from: text)
    }

    static func run(_ host: any BoundModel, _ op: String, _ args: String) async throws {
        guard await raw(host, op, args) == "null" else { throw Failed(op: op) }
    }

    static func face(_ person: Int, _ rng: inout SplitMix) throws -> String {
        var v = [Float](repeating: 0, count: 128)
        v[person] = 1
        for i in 0..<128 { v[i] += Float(rng.gaussian() * 0.6 / Double(128).squareRoot()) }
        let f = DetectedFace(box: Box(x0: 0.1, y0: 0.1, x1: 0.3, y1: 0.3), landmarks: [], confidence: 0.9,
                             faceprint: Faceprint(values: v))
        return try JSON.JSONEncoder().encodeToString(f)
    }

    @Test func aLibraryThroughTheBinding() async throws {
        let host = FaceBinding.make(cacheRoot: nil, directory: "/nonexistent")
        var rng = SplitMix(seed: 9)
        let h = try await Self.call(host, "library.open", as: Opened.self).handle
        for k in 0..<5 {
            for p in 0..<2 {
                let face = try Self.face(p, &rng)
                try await Self.run(host, "library.add",
                                   "{\"handle\":\(h),\"photo\":\"p\(p)-\(k)\",\"date\":\(1000 * k),\"faces\":[\(face)]}")
            }
        }
        try await Self.run(host, "library.regroup", "{\"handle\":\(h)}")
        let people = try await Self.call(host, "library.people", "{\"handle\":\(h)}", as: [FaceLibrary.Person].self)
        #expect(people.count == 2 && people.allSatisfy { $0.photoCount == 5 })

        let record = try await Self.call(host, "library.face", "{\"handle\":\(h),\"id\":\"p0-0#0\"}", as: FaceRecord.self)
        let noor = try #require(record.person)
        #expect(record.date == Date(timeIntervalSince1970: 0))
        try await Self.run(host, "library.name", "{\"handle\":\(h),\"person\":\(noor),\"name\":\"Noor\"}")
        try await Self.run(host, "library.reject", "{\"handle\":\(h),\"id\":\"p0-1#0\",\"person\":\(noor)}")
        let changes = try await Self.call(host, "library.takeChanges", "{\"handle\":\(h)}", as: [FaceRecord].self)
        #expect(changes.count == 10, "every face once: they were all new")
        let ana = try await Self.call(host, "library.newPerson", "{\"handle\":\(h),\"id\":\"p0-1#0\",\"name\":\"Ana\"}", as: Int?.self)
        #expect(ana != nil && ana != noor)
        let names = try await Self.call(host, "library.names", "{\"handle\":\(h)}", as: [String: String].self)
        #expect(names == [String(noor): "Noor", String(ana ?? -1): "Ana"])

        var probe = try Self.face(1, &rng)
        probe = String(probe[probe.range(of: "\"faceprint\":")!.upperBound...].dropLast())
        let who = try await Self.call(host, "library.personFor", "{\"handle\":\(h),\"faceprint\":\(probe)}", as: FaceLibrary.Person?.self)
        #expect(who?.photoCount == 5)

        let saved = try #require(await Self.raw(host, "library.save", "{\"handle\":\(h)}"))
        try await Self.run(host, "library.close", "{\"handle\":\(h)}")
        let h2 = try await Self.call(host, "library.open", "{\"library\":\(saved)}", as: Opened.self).handle
        let again = try await Self.call(host, "library.people", "{\"handle\":\(h2)}", as: [FaceLibrary.Person].self)
        #expect(Set(again.compactMap(\.name)) == ["Noor", "Ana"])
        #expect(await Self.raw(host, "library.people", "{\"handle\":\(h)}") == nil, "a closed handle answers nothing")
    }

#if !os(WASI)
    @Suite(.serialized, .modelBacked)
    struct ModelTests {
        @Test func facesThroughTheBindingMatchTheSwiftAPI() async throws {
            let image = try FaceTests.photo("group")
            let host = FaceBinding.make(cacheRoot: nil, directory: ProcessInfo.processInfo.environment["FACE_MODEL_DIR"])
            let decoded = try await BindingTests.call(host, "faces", as: [DetectedFace].self, image: image)
            let swift = try await FaceTests.makeFace().faces(in: image)
            #expect(decoded.count == swift.count && decoded.count == 2)
            for (a, b) in zip(decoded, swift) {
                #expect(a.faceprint.similarity(to: b.faceprint) > 0.9999)
                #expect(abs(a.confidence - b.confidence) < 1e-9)
            }
            let one = try await BindingTests.call(host, "faces", "{\"maxFaces\":1}", as: [DetectedFace].self, image: image)
            #expect(one.count == 1)
        }

        @Test func theDetectorVariantFindsTheSameFaces() async throws {
            let image = try FaceTests.photo("group")
            let directory = ProcessInfo.processInfo.environment["FACE_MODEL_DIR"]
            let host = try #require(FaceBinding.make(id: "face/detector", cacheRoot: nil, directory: directory))
            #expect(FaceBinding.make(id: "face/nothing", cacheRoot: nil, directory: directory) == nil)
            let found = try await BindingTests.call(host, "faces", "{\"minimumConfidence\":0.35}", as: [FaceDetection].self,
                                                    image: image)
            #expect(found == (try await FaceTests.makeFace().faces(in: image)).map(\.detection))
        }
    }
#endif
}
