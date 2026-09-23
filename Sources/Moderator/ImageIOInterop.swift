#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO

// Apple-only ergonomics: analyze a `CGImage`, an image file, or encoded image
// data directly. Every path ends in `ImagePixels`, so the crops and scores are
// the ones every other platform computes.

public extension ImagePixels {
    /// The image's pixels as sRGB RGBA8. Alpha is dropped by the model.
    init(_ image: CGImage) throws {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw ModeratorError.invalidImage }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ModeratorError.invalidImage }
        try self.init(width: width, height: height, rgba: bytes)
    }

    /// Decode an image file (JPEG, PNG, HEIC, ...), upright per its EXIF orientation.
    init(contentsOf url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ModeratorError.invalidImage }
        try self.init(source)
    }

    /// Decode encoded image data (JPEG, PNG, HEIC, ...), upright per its EXIF orientation.
    init(data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw ModeratorError.invalidImage }
        try self.init(source)
    }

    private init(_ source: CGImageSource) throws {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard let image = CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw ModeratorError.invalidImage }
        self = try ImagePixels(image).oriented(exif: orientation)
    }
}

#if canImport(UIKit)
import UIKit

public extension ImagePixels {
    /// A `UIImage`'s pixels at full resolution, upright per `imageOrientation`.
    init(_ image: UIImage) throws {
        if image.imageOrientation == .up, let cgImage = image.cgImage {
            try self.init(cgImage)
            return
        }
        // Renders at the image's own scale, so @2x/@3x and oriented images keep
        // every pixel; also covers CIImage-backed images, which have no cgImage.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.preferredRange = .standard  // 8-bit sRGB, not the device's extended range
        let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let cgImage = rendered.cgImage else { throw ModeratorError.invalidImage }
        try self.init(cgImage)
    }
}

public extension Moderator {
    /// Score a `UIImage` (orientation applied, full resolution).
    func analyze(_ image: UIImage, options: Options = .init()) async throws -> Moderation {
        try await analyze(ImagePixels(image), options: options)
    }
}
#elseif canImport(AppKit)
import AppKit

public extension ImagePixels {
    /// An `NSImage`'s pixels from its largest bitmap representation.
    init(_ image: NSImage) throws {
        // A rect in points would pick a low-resolution representation on Retina
        // images, so ask for the largest representation's pixel size.
        let best = image.representations.max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        var rect = CGRect(origin: .zero, size: image.size)
        if let best, best.pixelsWide > 0, best.pixelsHigh > 0 {
            rect.size = CGSize(width: best.pixelsWide, height: best.pixelsHigh)
        }
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw ModeratorError.invalidImage
        }
        try self.init(cgImage)
    }
}

public extension Moderator {
    /// Score an `NSImage` (its largest bitmap representation).
    func analyze(_ image: NSImage, options: Options = .init()) async throws -> Moderation {
        try await analyze(ImagePixels(image), options: options)
    }
}
#endif

public extension Moderator {
    /// Score a `CGImage`.
    func analyze(_ image: CGImage, options: Options = .init()) async throws -> Moderation {
        try await analyze(ImagePixels(image), options: options)
    }

    /// Score an image file (any format ImageIO reads; EXIF orientation applied).
    func analyze(contentsOf url: URL, options: Options = .init()) async throws -> Moderation {
        try await analyze(ImagePixels(contentsOf: url), options: options)
    }

    /// Score encoded image data (any format ImageIO reads; EXIF orientation applied).
    func analyze(data: Data, options: Options = .init()) async throws -> Moderation {
        try await analyze(ImagePixels(data: data), options: options)
    }
}
#endif
