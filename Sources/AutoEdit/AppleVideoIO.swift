#if canImport(AVFoundation)
import AVFoundation
import Foundation
import Transcript

extension VideoIO {
    /// The AVFoundation implementation of ``VideoIO/write(_:ranges:to:)``.
    static func appleWrite(
        _ source: URL,
        ranges: [TimeRange],
        to destination: URL
    ) async throws -> URL {
        let composition = try await composition(of: AVURLAsset(url: source), keeping: ranges)

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw AutoEditError.exportFailed("no export preset supports this recording")
        }

        let target = firstFreeName(from: destination)
        do {
            try await session.export(to: target, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw AutoEditError.exportFailed("\(error)")
        }
        return target
    }

    /// Lays the given spans of `asset` end to end.
    ///
    /// The result is playable as it is, so previewing and writing a clip use
    /// the same call.
    static func composition(
        of asset: AVAsset,
        keeping ranges: [TimeRange]
    ) async throws -> AVComposition {
        let composition = AVMutableComposition()
        let sourceVideo = try await asset.loadTracks(withMediaType: .video).first
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
        guard sourceVideo != nil || sourceAudio != nil else {
            throw AutoEditError.noPlayableTrack
        }
        let sourceSpan = try await CMTimeRange(start: .zero, duration: asset.load(.duration))

        let video = sourceVideo.flatMap { _ in
            composition.addMutableTrack(withMediaType: .video,
                                        preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        let audio = sourceAudio.flatMap { _ in
            composition.addMutableTrack(withMediaType: .audio,
                                        preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        var cursor = CMTime.zero
        for range in ranges {
            let span = CMTimeRange(
                start: CMTime(seconds: range.start, preferredTimescale: 600),
                duration: CMTime(seconds: range.duration, preferredTimescale: 600)
            ).intersection(sourceSpan)
            guard span.duration > .zero else { continue }

            if let sourceVideo, let video {
                try video.insertTimeRange(span, of: sourceVideo, at: cursor)
            }
            if let sourceAudio, let audio {
                try audio.insertTimeRange(span, of: sourceAudio, at: cursor)
            }
            cursor = cursor + span.duration
        }

        // Carries the source's rotation, so portrait footage stays portrait.
        if let sourceVideo, let video {
            video.preferredTransform = try await sourceVideo.load(.preferredTransform)
        }
        return composition
    }
}
#endif
