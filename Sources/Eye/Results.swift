import DesertAnt

/// Decoded RGB(A) pixels, row-major from the top-left, 8 bits per channel. The
/// portable input every platform funnels into: Apple builds one from a
/// `CGImage` or file, Android from a `Bitmap`, the web from `ImageData`.
/// Alpha is ignored.
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

    init(width: Int, height: Int, channels: Int, bytes: [UInt8]) throws {
        guard width > 0, height > 0, channels == 3 || channels == 4,
              bytes.count == width * height * channels else { throw EyeError.invalidImage }
        self.width = width
        self.height = height
        self.channels = channels
        self.bytes = bytes
    }
}

/// Which parts of an ``Analysis`` to compute. Each is one or more model runs, so
/// leave out what you do not read.
public struct Parts: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// What the photo is and how good: the 384x384 centre crop (types, scenes,
    /// reject reasons, sensitive content, scores, embedding).
    public static let photo = Parts(rawValue: 1)
    /// Where things are, from the whole frame: people and pet boxes, crops.
    /// Pet boxes are gated by the photo's scenes, so this runs the photo part too.
    public static let layout = Parts(rawValue: 2)
    /// Faces: detection on the whole frame, then one run per face.
    public static let faces = Parts(rawValue: 4)
    /// Sharpness.
    public static let sharpness = Parts(rawValue: 8)
    public static let all: Parts = [.photo, .layout, .faces, .sharpness]
}

/// Options for one ``Eye/analyze(_:options:)`` call.
public struct Options: Sendable, Hashable {
    /// What to compute. Default: everything.
    public var parts: Parts
    /// At most this many faces are analyzed, the most confident first. Default 20.
    public var maxFaces: Int

    public init(parts: Parts = .all, maxFaces: Int = 20) {
        self.parts = parts
        self.maxFaces = max(0, maxFaces)
    }
}

/// An axis-aligned rectangle in `0...1` of the image's width and height, origin
/// at the top left.
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

/// The photo function's raw outputs, from the centre crop.
public struct Photo: Sendable {
    /// 512-dimensional, unit length: the dot product of two embeddings is their
    /// cosine similarity (near-duplicates, search, clustering).
    public let embedding: [Float]
    /// What kind of image it is (`photo`, `selfie`, `screenshot`, `receipt`, ...):
    /// probabilities that sum to 1.
    public let type: [String: Double]
    /// Why the photo might not be worth keeping (`forgettable`, `accidental`,
    /// `technical_flaw`, ...), each `0...1` on its own. `keeper` is the opposite.
    public let reject: [String: Double]
    /// Sensitive content (`nsfw_explicit`, `blood_injury`, `weapon`, ...), each `0...1`.
    public let sensitive: [String: Double]
    /// 565 Open Images classes (`Person`, `Dog`, `Beach`, ...), each `0...1` on its own.
    public let scenes: [String: Double]
    /// How far the photo is turned clockwise from upright (0, 90, 180 or 270
    /// degrees): probabilities that sum to 1. Turn it back counterclockwise by
    /// that much to fix it.
    public let rotation: [Int: Double]
    /// How good the photo is as a photograph, `0...1`.
    public let aesthetic: Double
    /// Ratings from 1 (poor) to 5 (excellent): `composition`, `lighting`,
    /// `color`, `subject_interest`, `timing`, `framing`, `tilt`,
    /// `background_clutter`, `intrusive_object`, `noise_low_light`.
    public let aestheticAttributes: [String: Double]
    /// Whether people keep a photo like this, `0...1`.
    public let keeper: Double
    /// Whether it would make a good cover or thumbnail, `0...1`.
    public let cover: Double
    /// The kind of blur: `none`, `defocus` or `motion`, probabilities that sum to 1.
    public let blur: [String: Double]
    /// Deliberate background blur (shallow depth of field); higher is more.
    /// A score, not a probability.
    public let bokeh: Double
    /// For a pet photo: `quality`, `face_visible`, `facing_camera`,
    /// `eyes_open`, `sharp`, `cut_off`, `occluded`, each `0...1`.
    public let pet: [String: Double]
    /// The peak of a moment: `airborne`, `peak` (of the action), `action`,
    /// `dramatic`, each `0...1`.
    public let peak: [String: Double]
}

/// One detected object.
public struct Detection: Sendable, Hashable, Codable {
    /// `person`, `cat` or `dog`.
    public let label: String
    public let confidence: Double
    public let box: Box
}

/// A crop candidate and how good a crop of the photo it is (higher is better).
public struct Crop: Sendable, Hashable, Codable {
    public let box: Box
    public let score: Double
}

/// Head pose in degrees.
public struct Pose: Sendable, Hashable, Codable {
    public let yaw: Double
    public let pitch: Double
    public let roll: Double
}

/// Everything the model read from one face: ``Face`` has its tags; this has
/// the raw outputs behind them.
public struct FaceDetails: Sendable {
    public let box: Box
    /// Detection confidence, `0...1`.
    public let confidence: Double
    /// Left to right in the image: left eye, right eye, nose tip, left and right
    /// mouth corners.
    public let landmarks: [Point]
    /// Whether the crop is a face at all, `0...1` (faces below 0.5 are dropped).
    public let isFace: Double
    /// A real face rather than a statue, painting or screen, `0...1`.
    public let isReal: Double
    public let eyesOpen: Double
    /// How closed each eye is: `left`, `right`, `0...1`.
    public let blink: [String: Double]
    public let smile: Double
    /// `closed`, `talking`, `laughing`, `other_open`: probabilities that sum to 1.
    public let mouth: [String: Double]
    /// `neutral`, `happy`, `surprised`, `awkward_or_grimace`, `sad_or_angry`:
    /// probabilities that sum to 1.
    public let expression: [String: Double]
    /// Looking into the camera, `0...1`.
    public let looking: Double
    /// `sunglasses`, `face_mask`, `hand_or_object_covering`, `cut_off_by_frame`, each `0...1`.
    public let occlusion: [String: Double]
    /// The face is in focus, `0...1`.
    public let sharp: Double
    /// `good`, `dark`, `overexposed`, `harsh_shadows`: probabilities that sum to 1.
    public let lighting: [String: Double]
    /// A shot of this face worth keeping, `0...1`.
    public let keepsake: Double
    public let pose: Pose
    /// Overall quality of the face in this photo, `0...1`.
    public let quality: Double
}

/// How sharp the photo is.
public struct Sharpness: Sendable {
    /// The probability that a person calls the photo sharp, `0...1`.
    public let score: Double
    /// Blur over the image, higher is blurrier (row-major, about 1/16 of the input).
    public let blurMap: Details.Grid
}

/// The model's raw outputs behind an ``Analysis``, for when tags and scores are
/// not enough. A part not asked for is `nil`. Not stored: an analysis decoded
/// from JSON has none.
public struct Details: Sendable {
    public let photo: Photo?
    public let layout: Layout?
    /// In the order of ``Analysis/faces``.
    public let faces: [FaceDetails]?
    public let sharpness: Sharpness?
}

// Nested so they don't clash with SwiftUI's `Layout` and `Grid` in a file that imports both.
extension Details {
    /// The spatial function's raw outputs, from the whole frame.
    public struct Layout: Sendable {
        /// Where people look when they see the photo: 64x64, sums to 1.
        public let attention: Grid
        public let people: [Detection]
        /// Cats and dogs.
        public let pets: [Detection]
        /// How the main person is framed: `extreme_close_up`, `close_up`, `medium`,
        /// `wide`, probabilities that sum to 1. Meaningful when ``people`` is not empty.
        public let shot: [String: Double]
        /// Every crop candidate with its score, in the model's candidate order.
        public let crops: [Crop]
    }

    /// A map over the image, row-major from the top left.
    public struct Grid: Sendable, Hashable {
        public let width: Int
        public let height: Int
        public let values: [Float]

        public init(width: Int, height: Int, values: [Float]) {
            self.width = width
            self.height = height
            self.values = values
        }

        /// The value at column `x`, row `y`.
        public subscript(x: Int, y: Int) -> Float { values[y * width + x] }
    }
}

/// Errors thrown while loading or running the model.
public enum EyeError: MessageError, Sendable {
    /// A model resource was missing or unreadable.
    case resourceMissing
    /// The image could not be decoded, or its pixel buffer does not match its size.
    case invalidImage
    /// On-device inference failed or returned an unexpected output.
    case predictionFailed

    public var message: String {
        switch self {
        case .resourceMissing: "An Eye model resource was not found."
        case .invalidImage: "Eye could not read the image."
        case .predictionFailed: "On-device photo analysis failed."
        }
    }
}
