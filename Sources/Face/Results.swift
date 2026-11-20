import DesertAnt
#if os(Android)
// Do not import Foundation on Android: it pulls in the full ICU payload.
// Use FoundationEssentials to keep ICU out of the SDK.
import FoundationEssentials
#else
import Foundation
#endif

/// Decoded RGB or RGBA pixels, row-major from the top left, 8 bits per channel.
/// Face and Eye read this type on every platform, and ignore alpha.
public struct ImagePixels: Sendable {
    public let width: Int
    public let height: Int
    /// Bytes per pixel: 4 for RGBA, 3 for RGB.
    public let channels: Int
    public let bytes: [UInt8]

    /// Interleaved RGBA bytes, `width * height * 4` of them.
    public init(width: Int, height: Int, rgba: [UInt8]) throws {
        try self.init(width: width, height: height, channels: 4, bytes: rgba)
    }

    /// Interleaved RGB bytes, `width * height * 3` of them.
    public init(width: Int, height: Int, rgb: [UInt8]) throws {
        try self.init(width: width, height: height, channels: 3, bytes: rgb)
    }

    package init(width: Int, height: Int, channels: Int, bytes: [UInt8]) throws {
        guard width > 0, height > 0, channels == 3 || channels == 4,
              bytes.count == width * height * channels else { throw FaceError.invalidImage }
        self.width = width
        self.height = height
        self.channels = channels
        self.bytes = bytes
    }
}

/// A rectangle in `0...1` of the image's width and height, origin at the top left.
public struct Box: Sendable, Hashable, Codable {
    public let x0: Double
    public let y0: Double
    public let x1: Double
    public let y1: Double

    public init(x0: Double, y0: Double, x1: Double, y1: Double) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }

    public var width: Double { x1 - x0 }
    public var height: Double { y1 - y0 }
}

/// A point in `0...1` of the image's width and height, origin at the top left.
public struct Point: Sendable, Hashable, Codable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// One face's identity: 128 numbers of unit length. Two faceprints of the same
/// person point the same way. Store a faceprint (`Faceprint` is `Codable`) and
/// compare faceprints later without loading the model. Compare faceprints of one
/// ``model`` only.
public struct Faceprint: Sendable, Hashable, Codable {
    /// The embedding, unit length.
    public let values: [Float]
    /// The embedder that made the faceprint, ``FaceModel/faceprintModel``.
    public let model: String

    /// A faceprint from stored values (scaled to unit length).
    public init(values: [Float], model: String = FaceModel.faceprintModel) {
        let norm = values.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        self.values = norm > 0 ? values.map { $0 / norm } : values
        self.model = model
    }

    init(exact values: [Float], model: String) {
        self.values = values
        self.model = model
    }

    /// One faceprint for a person seen in several photos: the direction of their
    /// mean. `nil` for an empty list or faceprints of different models.
    public init?(averaging faceprints: [Faceprint]) {
        guard let first = faceprints.first, faceprints.allSatisfy({ $0.model == first.model && $0.values.count == first.values.count })
        else { return nil }
        var sum = [Float](repeating: 0, count: first.values.count)
        for f in faceprints { for i in sum.indices { sum[i] += f.values[i] } }
        self.init(values: sum, model: first.model)
    }

    /// Cosine similarity, `-1...1`.
    /// 0 for faceprints of different lengths, which come from different embedders.
    public func similarity(to other: Faceprint) -> Double {
        guard values.count == other.values.count else { return 0 }
        return Double(zip(values, other.values).reduce(Float(0)) { $0 + $1.0 * $1.1 })
    }

    /// Whether `other` comes from the same embedder: the same model and length.
    public func isComparable(to other: Faceprint) -> Bool {
        model == other.model && values.count == other.values.count
    }

    /// Whether `other` is the same person at `level`.
    public func isSamePerson(as other: Faceprint, _ level: Level = .recommended) -> Bool {
        isComparable(to: other) && similarity(to: other) >= level.cutoff
    }

    /// The values as 512 bytes (little-endian float32), to store in your own database.
    public var data: Data {
        var d = Data(capacity: values.count * 4)
        for v in values { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }

    /// A faceprint from ``data`` and the ``model`` it was stored with. `nil` if `data` is not a whole number of floats.
    public init?(data: Data, model: String) {
        guard !data.isEmpty, data.count % 4 == 0 else { return nil }
        let values: [Float] = data.withUnsafeBytes { raw in
            (0..<(raw.count / 4)).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
        guard values.allSatisfy(\.isFinite) else { return nil }
        self.init(exact: values, model: model)
    }

    private enum CodingKeys: String, CodingKey { case model, data }

    /// A faceprint encodes as its model and its values in base64, about 700 bytes of JSON.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(data.base64EncodedString(), forKey: .data)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let model = try c.decode(String.self, forKey: .model)
        // Padding is optional, as some stores drop it.
        let text = try c.decode(String.self, forKey: .data)
        guard let bytes = Data(base64Encoded: text + String(repeating: "=", count: (4 - text.count % 4) % 4)),
              let f = Faceprint(data: bytes, model: model) else {
            throw DecodingError.dataCorruptedError(forKey: .data, in: c, debugDescription: "not a faceprint")
        }
        self = f
    }

    /// How sure a match must be.
    public enum Level: String, Sendable, Hashable, Codable, CaseIterable {
        /// One false match in 1,000 pairs of different people: albums, search, suggestions.
        case recommended
        /// One false match in 10,000: anything that acts without asking, such as sharing a photo with someone.
        case strict

        /// The cosine similarity at or above which two faceprints are the same person. We set the cutoffs on about 7
        /// million pairs of different people, including low resolution, video stills, decades apart, and every skin tone.
        public var cutoff: Double {
            switch self {
            case .recommended: 0.4129
            case .strict: 0.5116
            }
        }
    }
}

/// A face Face's `FaceDetector` found: where it is, without a faceprint.
public struct FaceDetection: Sendable, Hashable, Codable {
    /// Where the face is.
    public let box: Box
    /// Left eye, right eye, nose tip, left and right mouth corner (image left and right).
    public let landmarks: [Point]
    /// The detector's confidence, `0...1`. Blurred, dark, turned-away and partly hidden faces score low, and so do
    /// most things that are not faces.
    public let confidence: Double

    public init(box: Box, landmarks: [Point], confidence: Double) {
        self.box = box
        self.landmarks = landmarks
        self.confidence = confidence
    }
}

/// A face Face found, with its faceprint.
public struct DetectedFace: Sendable, Hashable, Codable {
    /// Where the face is.
    public let box: Box
    /// Left eye, right eye, nose tip, left and right mouth corner (image left and right).
    public let landmarks: [Point]
    /// The detector's confidence, `0...1`. Of the signals we tested, the confidence predicts best how well Face
    /// recognises a face, better than the face's size, pose or sharpness. Blurred, dark, turned-away and partly
    /// hidden faces score low, and so do most things that are not faces. `FaceLibrary` doesn't start groups from
    /// faces under 0.5; those faces join a person only when they clearly match.
    public let confidence: Double
    /// The face's identity, to compare with other faces.
    public let faceprint: Faceprint

    public init(box: Box, landmarks: [Point], confidence: Double, faceprint: Faceprint) {
        self.box = box
        self.landmarks = landmarks
        self.confidence = confidence
        self.faceprint = faceprint
    }

    /// A detection and the faceprint made from it.
    public init(_ detection: FaceDetection, faceprint: Faceprint) {
        self.init(box: detection.box, landmarks: detection.landmarks, confidence: detection.confidence,
                  faceprint: faceprint)
    }

    /// Where the face is, without its faceprint.
    public var detection: FaceDetection { FaceDetection(box: box, landmarks: landmarks, confidence: confidence) }
}

/// What can go wrong.
public enum FaceError: MessageError, Sendable {
    /// A model resource was missing or unreadable.
    case resourceMissing
    /// Face could not decode the image, or the pixel buffer does not match the image size.
    case invalidImage
    /// On-device inference failed or returned an unexpected output.
    case predictionFailed

    public var message: String {
        switch self {
        case .resourceMissing: "A Face model resource was not found."
        case .invalidImage: "Face could not read the image."
        case .predictionFailed: "On-device face analysis failed."
        }
    }
}
