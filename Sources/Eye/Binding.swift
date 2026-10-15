import DesertAnt
import JSON

extension Eye: BoundModel {
    /// Input payload: `u32 width`, `u32 height`, `u32 channels` (3 RGB or 4
    /// RGBA), then a length-prefixed blob of `width * height * channels` bytes.
    ///
    /// Options payload: `u32 parts` (the ``Parts`` bits), `u32 maxFaces`. An
    /// empty payload means the SDK defaults.
    ///
    /// Result payload: `string` the ``Analysis`` as JSON (the schema stored
    /// analyses use, so the bindings build theirs as they restore one), then
    /// its ``Details``, each part behind a `u32` present flag (1 or 0):
    /// - photo: `f32[] embedding`, then `dist` type, reject, sensitive, scenes,
    ///   rotation (names are the degrees), `f64 aesthetic`, `dist` aesthetic
    ///   attributes, `f64 keeper`, `f64 cover`, `dist` blur, `f64 bokeh`, `dist`
    ///   pet, `dist` peak;
    /// - layout: `grid` attention, `detections` people, `detections` pets, `dist`
    ///   shot, `f32[]` crops (`x0, y0, x1, y1, score` per candidate);
    /// - faces: `u32` count, then per face `box`, `f64 confidence`, `u32` landmark
    ///   count and `f64 x, f64 y` each, `f64` isFace, isReal, eyesOpen, `dist`
    ///   blink, `f64 smile`, `dist` mouth, `dist` expression, `f64 looking`, `dist`
    ///   occlusion, `f64 sharp`, `dist` lighting, `f64` keepsake, yaw, pitch,
    ///   roll, quality;
    /// - sharpness: `f64 score`, `grid` blur map.
    ///
    /// `dist` is `u32` count then (`string` name, `f64` value) pairs in the
    /// model's order; `grid` is `u32 width`, `u32 height`, `f32[]` values; `box`
    /// is `f64 x0, y0, x1, y1`; `detections` is `u32` count then (`string`
    /// label, `f64` confidence, `box`).
    public func run(input: FFIReader, options: FFIReader) async -> [UInt8]? {
        var input = input
        var options = options
        let width = input.u32(), height = input.u32(), channels = input.u32()
        guard let image = try? ImagePixels(width: width, height: height, channels: channels,
                                           bytes: input.blob()) else { return nil }
        let opts = options.isEmpty ? Options() : Options(parts: Parts(rawValue: options.u32()), maxFaces: options.u32())
        guard let result = try? await analyze(image, options: opts),
              let json = try? JSONEncoder().encodeToString(result) else { return nil }
        var w = FFIWriter()
        w.string(json)
        result.details?.write(to: &w)
        return w.bytes
    }
}

/// How the generic bindings construct Eye.
public enum EyeBinding: ModelBinding {
    public static let id = EyeModel.id

    public static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        Eye(directory: directory, cacheRoot: cacheRoot)
    }
}

extension Details {
    func write(to w: inout FFIWriter) {
        func dist(_ values: [String: Double], order: [String]) {
            w.u32(order.count)
            for name in order { w.string(name); w.f64(values[name] ?? 0) }
        }
        func box(_ b: Box) { for v in [b.x0, b.y0, b.x1, b.y1] { w.f64(v) } }
        func grid(_ g: Details.Grid) { w.u32(g.width); w.u32(g.height); w.f32Array(g.values) }
        func detections(_ d: [Detection]) {
            w.u32(d.count)
            for x in d { w.string(x.label); w.f64(x.confidence); box(x.box) }
        }
        // Sorted names keep the payload deterministic; the binding languages key by name.
        func ordered(_ d: [String: Double]) -> [String] { d.keys.sorted() }

        w.u32(photo == nil ? 0 : 1)
        if let p = photo {
            w.f32Array(p.embedding)
            for d in [p.type, p.reject, p.sensitive, p.scenes] { dist(d, order: ordered(d)) }
            let rotation = Dictionary(uniqueKeysWithValues: p.rotation.map { (String($0.key), $0.value) })
            dist(rotation, order: p.rotation.keys.sorted().map(String.init))
            w.f64(p.aesthetic)
            dist(p.aestheticAttributes, order: ordered(p.aestheticAttributes))
            w.f64(p.keeper)
            w.f64(p.cover)
            dist(p.blur, order: ordered(p.blur))
            w.f64(p.bokeh)
            dist(p.pet, order: ordered(p.pet))
            dist(p.peak, order: ordered(p.peak))
        }
        w.u32(layout == nil ? 0 : 1)
        if let l = layout {
            grid(l.attention)
            detections(l.people)
            detections(l.pets)
            dist(l.shot, order: ordered(l.shot))
            w.f32Array(l.crops.flatMap { [$0.box.x0, $0.box.y0, $0.box.x1, $0.box.y1, $0.score].map(Float.init) })
        }
        w.u32(faces == nil ? 0 : 1)
        if let faces {
            w.u32(faces.count)
            for f in faces {
                box(f.box)
                w.f64(f.confidence)
                w.u32(f.landmarks.count)
                for p in f.landmarks { w.f64(p.x); w.f64(p.y) }
                for v in [f.isFace, f.isReal, f.eyesOpen] { w.f64(v) }
                dist(f.blink, order: ordered(f.blink))
                w.f64(f.smile)
                dist(f.mouth, order: ordered(f.mouth))
                dist(f.expression, order: ordered(f.expression))
                w.f64(f.looking)
                dist(f.occlusion, order: ordered(f.occlusion))
                w.f64(f.sharp)
                dist(f.lighting, order: ordered(f.lighting))
                for v in [f.keepsake, f.pose.yaw, f.pose.pitch, f.pose.roll, f.quality] { w.f64(v) }
            }
        }
        w.u32(sharpness == nil ? 0 : 1)
        if let s = sharpness {
            w.f64(s.score)
            grid(s.blurMap)
        }
    }
}
