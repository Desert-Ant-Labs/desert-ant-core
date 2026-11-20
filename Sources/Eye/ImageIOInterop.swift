#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO

// Apple-only ergonomics: analyze a `CGImage`, an image file, or encoded image
// data directly. Every path ends in `ImagePixels` (Face's, which decodes them),
// so the inputs and results are the ones every other platform computes.

#if canImport(UIKit)
import UIKit

public extension Eye {
    /// Analyze a `UIImage` (orientation applied, full resolution).
    func analyze(_ image: UIImage, options: Options = .init()) async throws -> Analysis {
        try await analyze(ImagePixels(image), options: options)
    }
}
#elseif canImport(AppKit)
import AppKit

public extension Eye {
    /// Analyze an `NSImage` (its largest bitmap representation).
    func analyze(_ image: NSImage, options: Options = .init()) async throws -> Analysis {
        try await analyze(ImagePixels(image), options: options)
    }
}
#endif

public extension Eye {
    /// Analyze a `CGImage`.
    func analyze(_ image: CGImage, options: Options = .init()) async throws -> Analysis {
        try await analyze(ImagePixels(image), options: options)
    }

    /// Analyze an image file (any format ImageIO reads; EXIF orientation applied).
    func analyze(contentsOf url: URL, options: Options = .init()) async throws -> Analysis {
        try await analyze(ImagePixels(contentsOf: url), options: options)
    }

    /// Analyze encoded image data (any format ImageIO reads; EXIF orientation applied).
    func analyze(data: Data, options: Options = .init()) async throws -> Analysis {
        try await analyze(ImagePixels(data: data), options: options)
    }
}
#endif
