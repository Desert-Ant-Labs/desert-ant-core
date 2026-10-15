#if !os(WASI)
import Foundation
import Testing
import TestSupport
@testable import Eye

/// Images per second through the public API, opt-in: `EYE_BENCH=1` (and
/// `EYE_BENCH_N` runs per case, default 30). Prints one `EYE_BENCH` JSON line.
@Suite(.serialized, .modelBacked, .enabled(if: ProcessInfo.processInfo.environment["EYE_BENCH"] != nil, "set EYE_BENCH=1"))
struct ThroughputTests {
    @Test func throughput() async throws {
        let env = ProcessInfo.processInfo.environment
        let n = Int(env["EYE_BENCH_N"] ?? "") ?? 30
        let eye = env["EYE_MODEL_DIR"].map { Eye(directory: $0) } ?? Eye()
        let small = try EyeTests.fixture(try Golden.load())
        let images = [("fixture", small), ("12mp", Self.upscaled(small, width: 4032))]

        let loadStart = Date()
        _ = try await eye.analyze(small)
        var rows: [String] = ["\"first_ms\":\(Self.ms(since: loadStart))"]

        for (name, image) in images {
            for (partName, parts) in [("all", Parts.all), ("photo", Parts.photo)] {
                for _ in 0..<2 { _ = try await eye.analyze(image, options: .init(parts: parts)) }
                var start = Date()
                for _ in 0..<n { _ = try await eye.analyze(image, options: .init(parts: parts)) }
                let serial = Double(n) / Date().timeIntervalSince(start)
                start = Date()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    var next = 0
                    for _ in 0..<min(4, n) { next += 1; group.addTask { _ = try await eye.analyze(image, options: .init(parts: parts)) } }
                    while try await group.next() != nil, next < n {
                        next += 1
                        group.addTask { _ = try await eye.analyze(image, options: .init(parts: parts)) }
                    }
                }
                let parallel = Double(n) / Date().timeIntervalSince(start)
                rows.append(String(format: "\"%@_%@\":{\"serial\":%.2f,\"parallel4\":%.2f}", name, partName, serial, parallel))
            }
        }
        let rgb = Preprocess.rgb(images[1].1)
        for (step, f) in [("rgb", { _ = Preprocess.rgb(images[1].1) }), ("centre", { _ = Preprocess.centreCrop(rgb) }),
                          ("squash", { _ = Preprocess.squash(rgb) }), ("letterbox", { _ = Preprocess.letterbox(rgb) }),
                          ("sharp", { _ = Preprocess.sharp(rgb) })] as [(String, () -> Void)] {
            let start = Date()
            for _ in 0..<5 { f() }
            rows.append("\"prep_12mp_\(step)_ms\":\(Self.ms(since: start) / 5)")
        }
        print("EYE_BENCH {\(rows.joined(separator: ","))}")
    }

    static func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    /// Nearest-neighbour upscale, so a full-size photo carries the fixture's content.
    static func upscaled(_ image: ImagePixels, width: Int) -> ImagePixels {
        let height = width * image.height / image.width
        let src = image.bytes, c = src.count / (image.width * image.height)
        var out = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            let sy = y * image.height / height
            for x in 0..<width {
                let s = (sy * image.width + x * image.width / width) * c, d = (y * width + x) * 3
                out[d] = src[s]; out[d + 1] = src[s + 1]; out[d + 2] = src[s + 2]
            }
        }
        return try! ImagePixels(width: width, height: height, rgb: out)
    }
}
#endif
