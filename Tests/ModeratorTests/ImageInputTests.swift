#if canImport(ImageIO)
import Foundation
import ImageIO
import CoreGraphics
import Testing
import DesertAnt
import TestSupport
@testable import Moderator
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The Apple image inputs: every orientation decodes upright exactly as ImageIO's
/// own transformed decode does, and NSImage keeps full resolution.
struct ImageInputTests {
    /// An asymmetric RGB test image as a CGImage.
    static func cgImage(width: Int = 7, height: Int = 4) throws -> CGImage {
        let p = ModeratorTests.synthetic(width: width, height: height)
        let provider = try #require(CGDataProvider(data: Data(p.bytes) as CFData))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// A lossless PNG carrying an EXIF orientation.
    static func png(orientation: Int) throws -> Data {
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try cgImage(), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    @Test(arguments: 1...8)
    func orientationMatchesImageIO(orientation: Int) throws {
        let data = try Self.png(orientation: orientation)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let upright = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 7,
        ] as CFDictionary))
        let want = try ImagePixels(upright)
        let got = try ImagePixels(data: data)
        #expect(got.width == want.width && got.height == want.height)
        #expect(got.bytes == want.bytes)
    }

#if canImport(UIKit)
    /// A @2x image displayed rotated (`.right` is EXIF 6) decodes like the EXIF path.
    @Test func uiImageAppliesOrientationAtFullResolution() throws {
        let image = UIImage(cgImage: try Self.cgImage(), scale: 2, orientation: .right)
        let got = try ImagePixels(image)
        let want = try ImagePixels(data: try Self.png(orientation: 6))
        #expect(got.width == want.width && got.height == want.height)
        #expect(got.bytes == want.bytes)
    }
#elseif canImport(AppKit)
    @Test func nsImageKeepsFullResolution() throws {
        let cg = try Self.cgImage(width: 40, height: 20)
        // A Retina-style image: 40x20 pixels presented at 20x10 points.
        let image = NSImage(cgImage: cg, size: NSSize(width: 20, height: 10))
        let pixels = try ImagePixels(image)
        #expect(pixels.width == 40 && pixels.height == 20)
        #expect(pixels.bytes == (try ImagePixels(cg)).bytes)
    }
#endif

#if !os(WASI)
    @Suite(.serialized, .modelBacked)
    struct Cancellation {
        @Test func cancelledTaskThrows() async throws {
            let moderator = Moderator(directory: ProcessInfo.processInfo.environment["MODERATOR_MODEL_DIR"])
            try await moderator.download()
            let image = ModeratorTests.synthetic(width: 2000, height: 1500)
            let task = Task { try await moderator.analyze(image) }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }
#endif
}
#endif
