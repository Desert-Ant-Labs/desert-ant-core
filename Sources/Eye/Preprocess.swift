import DesertAnt
import FaceCore

/// The model inputs, built as the evaluation pipeline builds them (ml-eye
/// `evaluation/package.py`, Pillow), so a photo scores here as it did in the
/// numbers the model shipped on:
///
/// - `photo_peak`: short side to 384 (bicubic), the centre 384x384;
/// - `spatial`: the whole frame squashed to 384x384 (bicubic);
/// - `faces_analyze`: a square 1.4x the face box (black outside the image), to 128 (bilinear);
/// - `sharp_<aspect>`: gray (ITU-R 601 luma), to the closest shape (Lanczos).
///
/// Every tensor is `(1, C, H, W)` float32 in `0...1`.
enum Preprocess {
    typealias Plane = Pillow.Plane
    typealias Filter = Pillow.Filter

    static func rgb(_ image: ImagePixels) -> Plane { Pillow.rgb(image) }
    static func pyRound(_ v: Double) -> Int { Pillow.pyRound(v) }
    static func crop(_ image: Plane, x0: Int, y0: Int, width: Int, height: Int) -> Plane {
        Pillow.crop(image, x0: x0, y0: y0, width: width, height: height)
    }
    static func tensor(_ image: Plane) -> Tensor { Pillow.tensor(image) }
    static func resize(_ image: Plane, width: Int, height: Int, filter: Filter) -> Plane {
        Pillow.resize(image, width: width, height: height, filter: filter)
    }

    static func centreCrop(_ image: Plane, side: Int = 384) -> Plane {
        let s = Double(side) / Double(min(image.width, image.height))
        let w = max(side, pyRound(Double(image.width) * s)), h = max(side, pyRound(Double(image.height) * s))
        let r = resize(image, width: w, height: h, filter: .bicubic)
        return crop(r, x0: (w - side) / 2, y0: (h - side) / 2, width: side, height: side)
    }

    static func squash(_ image: Plane, side: Int = 384) -> Plane {
        resize(image, width: side, height: side, filter: .bicubic)
    }

    /// The analyzer's crop for a face box in image pixels.
    static func faceCrop(_ image: Plane, box: (x0: Double, y0: Double, x1: Double, y1: Double), side: Int = 128) -> Plane {
        let edge = 1.4 * max(box.x1 - box.x0, box.y1 - box.y0)
        let cx = (box.x0 + box.x1) / 2, cy = (box.y0 + box.y1) / 2
        let x0 = pyRound(cx - edge / 2), y0 = pyRound(cy - edge / 2)
        let x1 = pyRound(cx + edge / 2), y1 = pyRound(cy + edge / 2)
        return resize(crop(image, x0: x0, y0: y0, width: max(1, x1 - x0), height: max(1, y1 - y0)),
                      width: side, height: side, filter: .bilinear)
    }

    /// Gray at the sharpness shape closest to the photo's aspect, and that shape's function.
    static func sharp(_ image: Plane) -> (Plane, String) {
        let ratio = Double(image.height) / Double(image.width)
        let shape = EyeModel.sharpShapes.min {
            abs(Double($0.height) / Double($0.width) - ratio) < abs(Double($1.height) / Double($1.width) - ratio)
        }!
        return (resize(gray(image), width: shape.width, height: shape.height, filter: .lanczos), "sharp_\(shape.aspect)")
    }

    /// Pillow's RGB to L: `(R * 19595 + G * 38470 + B * 7471 + 0x8000) >> 16`.
    static func gray(_ image: Plane) -> Plane {
        var out = [UInt8](repeating: 0, count: image.width * image.height)
        for i in 0..<out.count {
            let r = Int(image.bytes[i * 3]), g = Int(image.bytes[i * 3 + 1]), b = Int(image.bytes[i * 3 + 2])
            out[i] = UInt8((r * 19595 + g * 38470 + b * 7471 + 0x8000) >> 16)
        }
        return Plane(width: image.width, height: image.height, channels: 1, bytes: out)
    }

}
