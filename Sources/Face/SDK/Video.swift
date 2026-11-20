#if canImport(AVFoundation) && canImport(CoreGraphics)
import AVFoundation
import CoreGraphics
import Foundation

/// The faces in one frame of a video.
public struct VideoFrame: Sendable {
    /// Seconds from the start of the video.
    public let time: Double
    /// The faces in the frame, most confident first.
    public let faces: [DetectedFace]

    /// The id to add this frame to a ``FaceLibrary`` with: `"<video>@<seconds>"`.
    public func photoID(in video: String) -> String {
        "\(video)@\(String(format: "%.3f", time))"
    }
}

public extension Face {
    /// The faces in a video, one frame every `seconds`, upright, in order. Add each
    /// frame to a ``FaceLibrary`` as a photo, with ``VideoFrame/photoID(in:)``, to
    /// see who is in the video. The library never puts two faces of one frame in one
    /// person. Each frame is read and analyzed when you ask for it, so a slow reader
    /// never has frames piling up. Cancelling the task stops the stream and throws
    /// `CancellationError`.
    func faces(inVideoAt url: URL, every seconds: Double = 1, options: Options = .recognition) -> AsyncThrowingStream<VideoFrame, Error> {
        Self.frames(inVideoAt: url, every: seconds) { try await self.faces(in: $0, options: options) }
    }

    /// The frames of the video at `url`, every `seconds`, each analyzed by `analyze` only when the reader asks for it.
    internal static func frames(
        inVideoAt url: URL, every seconds: Double,
        analyze: @escaping @Sendable (ImagePixels) async throws -> [DetectedFace]
    ) -> AsyncThrowingStream<VideoFrame, Error> {
        let reader = VideoReader(url: url, every: seconds)
        return AsyncThrowingStream {
            try Task.checkCancellation()
            guard let (time, image) = try await reader.next() else { return nil }
            return VideoFrame(time: time, faces: try await analyze(image))
        }
    }
}

/// Reads one frame at a time. The stream asks for the next frame only once the last one was taken, so it is never
/// read from two tasks at once.
private final class VideoReader: @unchecked Sendable {
    private let url: URL
    private let seconds: Double
    private var generator: AVAssetImageGenerator?
    private var duration = 0.0
    private var t = 0.0

    init(url: URL, every seconds: Double) {
        self.url = url
        self.seconds = seconds
    }

    func next() async throws -> (Double, ImagePixels)? {
        if generator == nil {
            let asset = AVURLAsset(url: url)
            duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, seconds > 0 else { throw FaceError.invalidImage }
            let g = AVAssetImageGenerator(asset: asset)
            g.appliesPreferredTrackTransform = true
            g.requestedTimeToleranceBefore = .zero
            g.requestedTimeToleranceAfter = .zero
            generator = g
        }
        guard let generator, t < duration else { return nil }
        let time = t
        let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        t += seconds
        return (time, try ImagePixels(image))
    }
}
#endif
