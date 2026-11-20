import DesertAnt

/// The detector's input: the photo letterboxed to a square, as ml-face-detect's evaluation builds it.
enum Preprocess {
    typealias Plane = Pillow.Plane
    typealias Filter = Pillow.Filter

    static func rgb(_ image: ImagePixels) -> Plane { Pillow.rgb(image) }
    static func pyRound(_ v: Double) -> Int { Pillow.pyRound(v) }
    static func tensor(_ image: Plane) -> Tensor { Pillow.tensor(image) }
    static func resize(_ image: Plane, width: Int, height: Int, filter: Filter) -> Plane {
        Pillow.resize(image, width: width, height: height, filter: filter)
    }

    static func letterbox(_ image: Plane, side: Int = 768) -> (Plane, Double) {
        let (r, s) = shrink(image, side: side)
        return (pad(r, side: side), s)
    }

    static func shrink(_ image: Plane, side: Int = 768) -> (Plane, Double) {
        let s = Double(side) / Double(max(image.width, image.height))
        let r = resize(image, width: max(1, pyRound(Double(image.width) * s)),
                       height: max(1, pyRound(Double(image.height) * s)), filter: .bilinear)
        return (r, s)
    }

    static func pad(_ r: Plane, side: Int = 768) -> Plane {
        var out = Plane(width: side, height: side, channels: 3, bytes: [UInt8](repeating: 114, count: side * side * 3))
        for y in 0..<min(r.height, side) {
            let n = min(r.width, side) * 3
            out.bytes.replaceSubrange((y * side * 3)..<(y * side * 3 + n), with: r.bytes[(y * r.width * 3)..<(y * r.width * 3 + n)])
        }
        return out
    }

}
