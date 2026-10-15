import Foundation
import Testing
import DesertAnt
import TestSupport
@testable import Eye

#if !os(WASI)
@Suite(.serialized, .modelBacked)
struct RotationTests {
    /// `degrees` must be a multiple of 90.
    static func turnedClockwise(_ image: ImagePixels, by degrees: Int) throws -> ImagePixels {
        var turned = image
        for _ in 0 ..< (((degrees % 360) + 360) % 360) / 90 {
            let (w, h, c) = (turned.width, turned.height, turned.channels)
            var bytes = [UInt8](repeating: 0, count: w * h * c)
            for y in 0 ..< w {
                for x in 0 ..< h {
                    let from = ((h - 1 - x) * w + y) * c, to = (y * h + x) * c
                    for k in 0 ..< c { bytes[to + k] = turned.bytes[from + k] }
                }
            }
            turned = try ImagePixels(width: h, height: w, channels: c, bytes: bytes)
        }
        return turned
    }

    private func makeEye() -> Eye {
        if let dir = ProcessInfo.processInfo.environment["EYE_MODEL_DIR"] { return Eye(directory: dir) }
        return Eye()
    }

    @Test(arguments: [90, 180, 270])
    func rotationIsHowFarThePhotoIsTurnedClockwise(_ turn: Int) async throws {
        let upright = try EyeTests.fixture(try Golden.load())
        let shown = try Self.turnedClockwise(upright, by: turn)
        let analysis = try await makeEye().analyze(shown, options: .init(parts: .photo))
        let reported = try #require(analysis.rotation, "the model did not flag the \(turn) degree turn")
        #expect(reported == turn)
        let corrected = try Self.turnedClockwise(shown, by: (360 - reported) % 360)
        #expect(corrected.bytes == upright.bytes)
    }

    @Test func theIntegerAgreesWithTheSidecarsLabels() async throws {
        let upright = try EyeTests.fixture(try Golden.load())
        let shown = try Self.turnedClockwise(upright, by: 90)
        let analysis = try await makeEye().analyze(shown, options: .init(parts: .photo))
        let distribution = try #require(analysis.details?.photo?.rotation)
        let turned = try #require(distribution.filter { $0.key != 0 }.max { $0.value < $1.value })
        #expect(analysis.rotation == turned.key)
    }
}
#endif
