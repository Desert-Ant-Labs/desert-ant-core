import DesertAnt

/// The face model: a face detector and a face embedder, downloaded on their own.
///
/// The detector finds faces and five landmarks on the photo scaled into a
/// 768 x 768 letterbox. The embedder turns a face, aligned on its landmarks to a
/// 128 x 128 crop, into a 128-number faceprint. `FaceDetector` and Eye download
/// the detector alone; `Face` downloads both. On Apple platforms the two graphs
/// are Core ML programs, every op on the Neural Engine; on every other platform
/// they are LiteRT files.
public enum FaceModel: ModelDeclaration {
    public static let id = "face"
    public static let product = "Face"
    public static let revision = "v1.0.0"
    public static let sdkVersion = "5.0.0"
    public static let summary = "On-device face matching across a photo library or through a video."

    /// The embedder this SDK's faceprints come from. Faceprints from different embedders don't compare.
    public static let faceprintModel = "face-1"

    /// The detector: Core ML 7.6 MB, LiteRT 15 MB.
    public static func detector(for platform: ModelPlatform) -> String {
        platform == .apple ? "face_detect.mlmodelc" : "face_detect.tflite"
    }

    /// The embedder: Core ML 18 MB, LiteRT 37 MB.
    public static func embedder(for platform: ModelPlatform) -> String {
        platform == .apple ? "face.mlmodelc" : "face.tflite"
    }

    public static let files: [ModelPlatform: [String]] = Dictionary(uniqueKeysWithValues: ModelPlatform.allCases.map {
        ($0, [entry(detector(for: $0)), entry(embedder(for: $0))])
    })

    public static func artifact(for platform: ModelPlatform) -> String { detector(for: platform) }

    /// The detector's files alone: what `FaceDetector` and Eye download.
    public static var detectorFiles: ModelDistribution {
        ModelDistribution(repo: repo, revision: revision, files: files.mapValues { [$0[0]] })
    }

    /// The embedder's files alone, which `Face` downloads beside the detector's.
    public static var embedderFiles: ModelDistribution {
        ModelDistribution(repo: repo, revision: revision, files: files.mapValues { [$0[1]] })
    }

    private static func entry(_ file: String) -> String { file.hasSuffix(".mlmodelc") ? file + "/" : file }

    struct Graph {
        let input: String
        let outputs: [String]
    }

    static func detectorGraph(for platform: ModelPlatform) -> Graph {
        platform == .apple
            ? Graph(input: "image", outputs: ["heatmap", "size", "offset", "landmarks"])
            : Graph(input: "args_0", outputs: ["output_0", "output_1", "output_2", "output_3"])
    }

    static func embedderGraph(for platform: ModelPlatform) -> Graph {
        platform == .apple
            ? Graph(input: "image", outputs: ["embedding"])
            : Graph(input: "args_0", outputs: ["output_0"])
    }
}
