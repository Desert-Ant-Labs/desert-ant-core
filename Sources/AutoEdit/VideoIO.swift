import Foundation
import Transcript

/// Cuts a recording down to a set of spans and writes the result.
///
/// The spans are laid end to end, so the gaps between them are removed rather
/// than played. Video keeps the source's rotation, and both tracks are carried
/// when the source has them.
public enum VideoIO {
    /// Writes the given spans of a recording as a new file.
    ///
    /// - Parameters:
    ///   - source: The recording to cut.
    ///   - ranges: The spans to keep, in ascending order.
    ///   - destination: Where to write the result. A file already at this path
    ///     is left alone and a numbered name is used instead.
    /// - Returns: The path written, which is `destination` unless a file was
    ///   already there.
    @discardableResult
    public static func write(
        _ source: URL,
        ranges: [TimeRange],
        to destination: URL
    ) async throws -> URL {
        #if canImport(AVFoundation)
        return try await appleWrite(source, ranges: ranges, to: destination)
        #else
        throw AutoEditError.unsupported("cutting video needs AVFoundation")
        #endif
    }

    /// Returns the first path in `url`'s folder that no file occupies.
    ///
    /// `url` itself when it is free, and `name-2`, `name-3`, and so on when it
    /// is not.
    static func firstFreeName(from url: URL) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path(percentEncoded: false)) else { return url }

        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let type = url.pathExtension

        for attempt in 2...9999 {
            let candidate = folder
                .appending(path: "\(stem)-\(attempt)")
                .appendingPathExtension(type)
            if !manager.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        return url
    }
}
