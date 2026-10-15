import DesertAnt

/// Runs eye's functions on one image and decodes their outputs.
final class Model: Sendable {
    private let sessions: [String: any InferenceSession]
    private let meta: Meta
    private let scene: [String: Int]

    init(assets: ModelAssets) {
        sessions = assets.sessions
        meta = assets.meta
        scene = Dictionary(uniqueKeysWithValues: assets.meta.labels.scenes.enumerated().map { ($1, $0) })
    }

    func analyze(_ image: ImagePixels, options: Options) async throws -> Analysis {
        let rgb = Preprocess.rgb(image)
        let parts = options.parts
        let photo = parts.contains(.photo) || parts.contains(.layout) ? try await self.photo(rgb) : nil
        let layout = parts.contains(.layout) ? try await self.layout(rgb, scenes: photo!.photo.scenes) : nil
        let faces = parts.contains(.faces) ? try await self.faces(rgb, limit: options.maxFaces) : nil
        let sharpness = parts.contains(.sharpness) ? try await self.sharpness(rgb) : nil
        let keepPhoto = parts.contains(.photo)
        return analysis(width: image.width, height: image.height, photo: keepPhoto ? photo : nil, layout: layout, faces: faces,
                        sharpness: sharpness)
    }

    /// The tags, scores and answers over the raw outputs.
    private func analysis(width: Int, height: Int, photo: (photo: Photo, outputs: [String: [Float]])?, layout: Details.Layout?,
                          faces: [FaceDetails]?, sharpness: Sharpness?) -> Analysis {
        let spec = meta.tags
        let inputs = faces?.map { f in
            TagSpec.FaceInput(box: f.box, confidence: f.confidence, isReal: f.isReal, signals: [
                "eyes_open": f.eyesOpen, "smile": f.smile, "looking": f.looking, "quality": f.quality,
            ].merging(f.expression.map { ("expression.\($0.key)", $0.value) }) { a, _ in a })
        }
        let (tags, faceTags) = spec.evaluate(outputs: photo?.outputs, sharpness: sharpness?.score, faces: inputs, width: width, height: height)
        var scores: Scores?
        var kind: Tag?
        var rotation: Int?
        if let p = photo {
            let s = spec.scores
            if let a = s["aesthetic"], let k = s["keeper"], let c = s["cover"] {
                scores = Scores(aesthetic: spec.percentile(p.photo.aesthetic, a), keeper: spec.percentile(p.photo.keeper, k),
                                cover: spec.percentile(p.photo.cover, c))
            }
            kind = p.photo.type.max { $0.value < $1.value }.map { Tag($0.key) }
            if (tags["rotated"] ?? 0) >= Level.recommended.cutoff, let r = p.outputs["rotation"], r.count == 4 {
                rotation = (r.indices.dropFirst().max { r[$0] < r[$1] } ?? 0) * 90
            }
        }
        let faceList = faces.map { fs in
            fs.enumerated().map { n, f in
                Face(box: f.box, detectionConfidence: f.confidence, landmarks: f.landmarks, pose: f.pose, quality: f.quality,
                     confidences: tagged(faceTags?[n] ?? [:]))
            }
        }
        return Analysis(model: "\(EyeModel.id)@\(EyeModel.revision)", width: width, height: height, confidences: tagged(tags),
                        kind: kind, scores: scores, rotation: rotation, embedding: photo?.photo.embedding,
                        people: layout?.people, pets: layout?.pets, faces: faceList,
                        crops: layout.map { Array($0.crops.sorted { $0.score > $1.score }.prefix(100)) },
                        details: Details(photo: photo?.photo, layout: layout, faces: faces, sharpness: sharpness),
                        duplicates: spec.duplicates)
    }

    /// One function's outputs by name, with their shapes.
    private func run(_ function: String, _ input: Preprocess.Plane, outputs: [String]) async throws -> [String: Tensor] {
        try Task.checkCancellation()
        guard let session = sessions[function] else { throw EyeError.resourceMissing }
        let out = try await session.run(inputs: ["image": Preprocess.tensor(input)], outputs: outputs)
        guard out.count == outputs.count else { throw EyeError.predictionFailed }
        return Dictionary(uniqueKeysWithValues: zip(outputs, out))
    }

    private func floats(_ t: Tensor?, count: Int? = nil) throws -> [Float] {
        guard let v = t?.float32Values, v.allSatisfy(\.isFinite), count.map({ v.count == $0 }) ?? true
        else { throw EyeError.predictionFailed }
        return v
    }

    private func photo(_ rgb: Preprocess.Plane) async throws -> (photo: Photo, outputs: [String: [Float]]) {
        let L = meta.labels
        let o = try await run("photo_peak", Preprocess.centreCrop(rgb), outputs: [
            "embedding", "type", "reject", "sensitive", "scenes", "rotation", "aesthetic", "keeper", "cover", "focus",
            "pet_attrs", "peak_logits",
        ])
        let d = { (k: String, n: Int?) in try self.floats(o[k], count: n).map(Double.init) }
        let aesthetic = try d("aesthetic", L.aesthetic.count), focus = try floats(o["focus"], count: L.focus.count)
        let raw = try Dictionary(uniqueKeysWithValues: ["type", "reject", "sensitive", "scenes", "rotation", "focus", "peak_logits"].map {
            ($0, try floats(o[$0]))
        })
        return (Photo(
            embedding: try floats(o["embedding"], count: 512),
            type: Decode.named(L.type, try d("type", nil)),
            reject: Decode.named(L.reject, try d("reject", nil)),
            sensitive: Decode.named(L.sensitive, try d("sensitive", nil)),
            scenes: Decode.named(L.scenes, try d("scenes", nil)),
            rotation: Dictionary(uniqueKeysWithValues: zip(L.rotation, try d("rotation", L.rotation.count))),
            aesthetic: aesthetic[0],
            aestheticAttributes: Decode.named(Array(L.aesthetic.dropFirst()), Array(aesthetic.dropFirst())),
            keeper: try d("keeper", 1)[0],
            cover: try d("cover", 1)[0],
            blur: Decode.named(Array(L.focus.prefix(3)), Decode.softmax(Array(focus.prefix(3)))),
            bokeh: Double(focus[3]),
            pet: Decode.named(L.petAttrs, try floats(o["pet_attrs"]).map(Decode.sigmoid)),
            peak: Decode.named(L.peakLogits, try floats(o["peak_logits"]).map(Decode.sigmoid))), raw)
    }

    private func layout(_ rgb: Preprocess.Plane, scenes: [String: Double]) async throws -> Details.Layout {
        let L = meta.labels
        let o = try await run("spatial", Preprocess.squash(rgb), outputs: [
            "subject", "pet_heatmap", "pet_size", "pet_offset", "person_heatmap", "person_size", "person_offset",
            "shot_logits", "crop_scores",
        ])
        func detections(_ head: String, labels: [String], rule: Meta.BoxDecoding,
                        gate: (Decode.Candidate) -> Double) throws -> [Detection] {
            var c = Decode.boxes(heatmap: try floats(o["\(head)_heatmap"]), size: try floats(o["\(head)_size"]),
                                 offset: try floats(o["\(head)_offset"]), classes: labels.count)
            for i in c.indices { c[i].confidence *= gate(c[i]) }
            return Decode.nms(c, iou: rule.nmsIoU, contain: rule.nmsContain).filter { $0.confidence >= rule.threshold }.map {
                Detection(label: labels[$0.label], confidence: $0.confidence, box: Box(x0: $0.x0, y0: $0.y0, x1: $0.x1, y1: $0.y1))
            }
        }
        let power = meta.pet.sceneGatePower ?? 1
        // pet confidences are gated by P(scene Cat / Dog) ^ power, as the box head was tuned with
        let gates = L.pets.map { name in scenes[name.prefix(1).uppercased() + name.dropFirst()].map { Double.pow($0, power) } ?? 1 }
        let attention = Decode.softmax(try floats(o["subject"], count: 64 * 64))
        let crops = try floats(o["crop_scores"], count: meta.cropCandidates.count)
        return Details.Layout(
            attention: Details.Grid(width: 64, height: 64, values: attention.map(Float.init)),
            people: try detections("person", labels: ["person"], rule: meta.person) { _ in 1 },
            pets: try detections("pet", labels: L.pets, rule: meta.pet) { gates[$0.label] },
            shot: Decode.named(L.shot, Decode.softmax(try floats(o["shot_logits"], count: L.shot.count))),
            crops: zip(meta.cropCandidates, crops).map { Crop(box: $0, score: Double($1)) })
    }

    private func faces(_ rgb: Preprocess.Plane, limit: Int) async throws -> [FaceDetails] {
        let L = meta.labels
        let (frame, scale) = Preprocess.letterbox(rgb)
        let o = try await run("faces_detect", frame, outputs: ["heatmap", "size", "offset", "landmarks"])
        guard let shape = o["heatmap"]?.shape, shape.count == 4 else { throw EyeError.predictionFailed }
        let found = Decode.faces(heatmap: try floats(o["heatmap"]), size: try floats(o["size"]), offset: try floats(o["offset"]),
                                 landmarks: try floats(o["landmarks"]), h: shape[2], w: shape[3])
        let W = Double(rgb.width), H = Double(rgb.height)
        var faces: [FaceDetails] = []
        for d in Decode.nms(found, iou: 0.4).filter({ $0.confidence >= 0.3 }).prefix(limit) {
            let box = (x0: d.x0 / scale, y0: d.y0 / scale, x1: d.x1 / scale, y1: d.y1 / scale)
            let r = try await run("faces_analyze", Preprocess.faceCrop(rgb, box: box), outputs: [
                "is_face", "is_real", "eyes_open", "blink", "smile", "mouth", "expression", "looking", "occlusion", "sharp",
                "lighting", "keepsake", "pose", "quality",
            ])
            let s = { (k: String) in Decode.sigmoid(try self.floats(r[k], count: 1)[0]) }
            let isFace = try s("is_face")
            guard isFace >= 0.5 else { continue }
            let pose = try floats(r["pose"], count: 3).map { Double($0) * 45 }
            faces.append(FaceDetails(
                box: Box(x0: box.x0 / W, y0: box.y0 / H, x1: box.x1 / W, y1: box.y1 / H),
                confidence: d.confidence,
                landmarks: d.landmarks.map { Point(x: $0.0 / scale / W, y: $0.1 / scale / H) },
                isFace: isFace,
                isReal: try s("is_real"),
                eyesOpen: try s("eyes_open"),
                blink: Decode.named(L.faceBlink, try floats(r["blink"]).map { Double(min(max($0, 0), 1)) }),
                smile: try s("smile"),
                mouth: Decode.named(L.faceMouth, Decode.softmax(try floats(r["mouth"]))),
                expression: Decode.named(L.faceExpression, Decode.softmax(try floats(r["expression"]))),
                looking: try s("looking"),
                occlusion: Decode.named(L.faceOcclusion, try floats(r["occlusion"]).map(Decode.sigmoid)),
                sharp: try s("sharp"),
                lighting: Decode.named(L.faceLighting, Decode.softmax(try floats(r["lighting"]))),
                keepsake: try s("keepsake"),
                pose: Pose(yaw: pose[0], pitch: pose[1], roll: pose[2]),
                quality: try s("quality")))
        }
        return faces
    }

    private func sharpness(_ rgb: Preprocess.Plane) async throws -> Sharpness {
        let (gray, function) = Preprocess.sharp(rgb)
        let o = try await run(function, gray, outputs: ["sharpness", "blur_map"])
        guard let shape = o["blur_map"]?.shape, shape.count >= 2 else { throw EyeError.predictionFailed }
        let h = shape[shape.count - 2], w = shape[shape.count - 1]
        return Sharpness(score: Double(try floats(o["sharpness"], count: 1)[0]),
                         blurMap: Details.Grid(width: w, height: h, values: try floats(o["blur_map"], count: w * h)))
    }
}
