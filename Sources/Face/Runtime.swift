import DesertAnt

/// A face the detector found, in the image's pixels: what ``FaceDetection``
/// normalises and clamps, and what the embedder aligns on. Eye crops its own
/// face analysis from it.
package struct PixelFace: Sendable {
    package let confidence: Double
    package let x0, y0, x1, y1: Double
    package let landmarks: [(x: Double, y: Double)]

    /// The same face in `0...1` of a `width` x `height` image.
    package func detection(width: Int, height: Int) -> FaceDetection {
        let W = Double(width), H = Double(height)
        return FaceDetection(
            box: Box(x0: max(0, x0 / W), y0: max(0, y0 / H), x1: min(1, x1 / W), y1: min(1, y1 / H)),
            landmarks: landmarks.map { Point(x: $0.x / W, y: $0.y / H) },
            confidence: confidence)
    }
}

/// Face's two graphs over a photo: the detector, and the embedder when the
/// faceprints are wanted. Shared by Face's `Face` and `FaceDetector` and by Eye,
/// which license the sessions as themselves.
package final class FaceRuntime: Sendable {
    private let detector: any InferenceSession
    private let embedder: (any InferenceSession)?
    private let detectorGraph: FaceModel.Graph
    private let embedderGraph: FaceModel.Graph

    package init(detector: any InferenceSession, embedder: (any InferenceSession)?, platform: ModelPlatform = .current) {
        self.detector = detector
        self.embedder = embedder
        detectorGraph = FaceModel.detectorGraph(for: platform)
        embedderGraph = FaceModel.embedderGraph(for: platform)
    }

    /// The sessions over resolved files: ``FaceModel/detectorFiles`` and, for
    /// faceprints, ``FaceModel/embedderFiles``.
    package static func load(detector: StoredModel, embedder: StoredModel?, sdk: SDKInfo = FaceModel.sdkInfo)
        async throws -> FaceRuntime {
        let platform = ModelPlatform.current
        let detect = try await detector.inferenceSession(model: FaceModel.detector(for: platform), sdk: sdk)
        guard let embedder else { return FaceRuntime(detector: detect, embedder: nil) }
        return FaceRuntime(detector: detect,
                           embedder: try await embedder.inferenceSession(model: FaceModel.embedder(for: platform), sdk: sdk))
    }

    /// Whether ``faceprint(_:in:)`` can run.
    package var makesFaceprints: Bool { embedder != nil }

    /// The faces in `image`, most confident first: at most `maxFaces` of them, each
    /// scoring at least `minimumConfidence` with a box at least `minimumSize`
    /// pixels on its shorter side.
    package func detect(_ image: ImagePixels, minimumConfidence: Double, minimumSize: Int, maxFaces: Int)
        async throws -> [PixelFace] {
        let rgb = Preprocess.rgb(image)
        let (frame, scale) = Preprocess.letterbox(rgb)
        let out = try await detector.run(inputs: [detectorGraph.input: Preprocess.tensor(frame)],
                                         outputs: detectorGraph.outputs)
        guard out.count == 4, out[0].shape.count == 4 else { throw FaceError.predictionFailed }
        let h = out[0].shape[2], w = out[0].shape[3]
        let v = try out.map { t -> [Float] in
            guard let f = t.float32Values, f.allSatisfy(\.isFinite) else { throw FaceError.predictionFailed }
            return f
        }
        let found = Decode.nms(Decode.faces(heatmap: v[0], size: v[1], offset: v[2], landmarks: v[3], h: h, w: w))
        return found.map { $0.scaled(by: 1 / scale) }.filter { c in
            c.confidence >= minimumConfidence && min(c.x1 - c.x0, c.y1 - c.y0) >= Double(minimumSize)
        }.prefix(max(0, maxFaces)).map {
            PixelFace(confidence: $0.confidence, x0: $0.x0, y0: $0.y0, x1: $0.x1, y1: $0.y1,
                      landmarks: $0.landmarks.map { (x: $0.0, y: $0.1) })
        }
    }

    /// The faceprint of `face`, aligned on its landmarks.
    package func faceprint(_ face: PixelFace, in image: ImagePixels) async throws -> Faceprint {
        guard let embedder else { throw FaceError.resourceMissing }
        let crop = Align.crop(Preprocess.rgb(image), landmarks: face.landmarks.map { ($0.x, $0.y) })
        let out = try await embedder.run(inputs: [embedderGraph.input: Preprocess.tensor(crop)],
                                         outputs: embedderGraph.outputs)
        guard let e = out.first?.float32Values, e.count == 128, e.allSatisfy(\.isFinite) else {
            throw FaceError.predictionFailed
        }
        return Faceprint(values: e)
    }

    /// Every face in `image` with its faceprint.
    package func faces(_ image: ImagePixels, minimumConfidence: Double, minimumSize: Int, maxFaces: Int)
        async throws -> [DetectedFace] {
        let rgb = try ImagePixels(width: image.width, height: image.height, channels: 3, bytes: Preprocess.rgb(image).bytes)
        var faces: [DetectedFace] = []
        for face in try await detect(rgb, minimumConfidence: minimumConfidence, minimumSize: minimumSize, maxFaces: maxFaces) {
            try Task.checkCancellation()
            faces.append(DetectedFace(face.detection(width: rgb.width, height: rgb.height),
                                      faceprint: try await faceprint(face, in: rgb)))
        }
        return faces
    }
}
