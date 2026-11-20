#if !os(WASI)
import Foundation
import Testing
import TestSupport
@testable import Face
@testable import FaceCore

/// Speed through the public API, opt-in: `FACE_BENCH=1` (and `FACE_BENCH_N` runs per case, default 30). Prints one
/// `FACE_BENCH` JSON line: median milliseconds per photo for `FaceDetector` and `Face`, on the test photo with two faces
/// (900 x 420) and on it scaled to 12 MP, and seconds to add 20,000 faces to a library one photo at a time and group them.
@Suite(.serialized, .modelBacked, .enabled(if: ProcessInfo.processInfo.environment["FACE_BENCH"] != nil, "set FACE_BENCH=1"))
struct BenchTests {
    @Test func speed() async throws {
        let env = ProcessInfo.processInfo.environment
        let n = Int(env["FACE_BENCH_N"] ?? "") ?? 30
        let face = FaceTests.makeFace(), detector = FaceTests.makeDetector()
        let small = try FaceTests.photo("group")
        let images = [("photo", small), ("12mp", Self.scaled(small, width: 5070))]

        var start = Date()
        _ = try await face.faces(in: small)
        var rows = ["\"face_first_ms\":\(Self.ms(since: start))"]
        start = Date()
        _ = try await detector.faces(in: small)
        rows.append("\"detector_first_ms\":\(Self.ms(since: start))")

        for (name, image) in images {
            rows.append("\"detector_\(name)_ms\":\(try await Self.median(n) { _ = try await detector.faces(in: image) })")
            let found = try await face.faces(in: image).count
            rows.append("\"face_\(name)_ms\":\(try await Self.median(n) { _ = try await face.faces(in: image) })")
            rows.append("\"face_\(name)_faces\":\(found)")
        }

        var library = FaceLibrary()
        var rng = SplitMix(seed: 7)
        let photos = 5000
        start = Date()
        for k in 0..<photos {
            library.add((0..<4).map { i in
                DetectedFace(box: Box(x0: 0.1, y0: 0.1, x1: 0.3, y1: 0.3), landmarks: [], confidence: 0.9,
                             faceprint: FaceTests.noisy((k * 4 + i) % 500, &rng, 0.6))
            }, photo: "img\(k)")
        }
        library.regroup()
        rows.append(String(format: "\"library_20000_s\":%.2f", Date().timeIntervalSince(start)))
        print("FACE_BENCH {\(rows.joined(separator: ","))}")
    }

    static func ms(since start: Date) -> String { String(format: "%.1f", Date().timeIntervalSince(start) * 1000) }

    /// Median milliseconds of `n` runs, after two warm-up runs.
    static func median(_ n: Int, _ body: () async throws -> Void) async throws -> String {
        for _ in 0..<2 { try await body() }
        var times: [Double] = []
        for _ in 0..<n {
            let start = Date()
            try await body()
            times.append(Date().timeIntervalSince(start) * 1000)
        }
        return String(format: "%.1f", times.sorted()[times.count / 2])
    }

    /// `image` scaled to `width` pixels wide, nearest neighbour.
    static func scaled(_ image: ImagePixels, width: Int) -> ImagePixels {
        let height = image.height * width / image.width, c = image.channels
        var out = [UInt8](repeating: 0, count: width * height * c)
        for y in 0..<height {
            let sy = y * image.height / height
            for x in 0..<width {
                let s = (sy * image.width + x * image.width / width) * c, d = (y * width + x) * c
                for k in 0..<c { out[d + k] = image.bytes[s + k] }
            }
        }
        return try! ImagePixels(width: width, height: height, channels: c, bytes: out)
    }
}
#endif
