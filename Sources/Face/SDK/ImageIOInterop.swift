#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO

#if canImport(UIKit)
import UIKit

public extension Face {
    /// The faces in a `UIImage` (orientation applied, full resolution).
    func faces(in image: UIImage, options: Options = .recognition) async throws -> [DetectedFace] {
        try await faces(in: ImagePixels(image), options: options)
    }
}

public extension FaceDetector {
    /// The faces in a `UIImage` (orientation applied, full resolution).
    func faces(in image: UIImage, options: Options = .init()) async throws -> [FaceDetection] {
        try await faces(in: ImagePixels(image), options: options)
    }
}
#elseif canImport(AppKit)
import AppKit

public extension Face {
    /// The faces in an `NSImage` (its largest bitmap representation).
    func faces(in image: NSImage, options: Options = .recognition) async throws -> [DetectedFace] {
        try await faces(in: ImagePixels(image), options: options)
    }
}

public extension FaceDetector {
    /// The faces in an `NSImage` (its largest bitmap representation).
    func faces(in image: NSImage, options: Options = .init()) async throws -> [FaceDetection] {
        try await faces(in: ImagePixels(image), options: options)
    }
}
#endif

public extension Face {
    /// The faces in a `CGImage`.
    func faces(in image: CGImage, options: Options = .recognition) async throws -> [DetectedFace] {
        try await faces(in: ImagePixels(image), options: options)
    }

    /// The faces in an image file (any format ImageIO reads; EXIF orientation applied).
    func faces(contentsOf url: URL, options: Options = .recognition) async throws -> [DetectedFace] {
        try await faces(in: ImagePixels(contentsOf: url), options: options)
    }

    /// The faces in encoded image data (any format ImageIO reads; EXIF orientation applied).
    func faces(data: Data, options: Options = .recognition) async throws -> [DetectedFace] {
        try await faces(in: ImagePixels(data: data), options: options)
    }
}

public extension FaceDetector {
    /// The faces in a `CGImage`.
    func faces(in image: CGImage, options: Options = .init()) async throws -> [FaceDetection] {
        try await faces(in: ImagePixels(image), options: options)
    }

    /// The faces in an image file (any format ImageIO reads; EXIF orientation applied).
    func faces(contentsOf url: URL, options: Options = .init()) async throws -> [FaceDetection] {
        try await faces(in: ImagePixels(contentsOf: url), options: options)
    }

    /// The faces in encoded image data (any format ImageIO reads; EXIF orientation applied).
    func faces(data: Data, options: Options = .init()) async throws -> [FaceDetection] {
        try await faces(in: ImagePixels(data: data), options: options)
    }
}
#endif
