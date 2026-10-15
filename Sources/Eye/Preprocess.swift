import DesertAnt
#if canImport(Dispatch) && !os(WASI)
import Dispatch
import Foundation
#endif
import RealModule

/// The model inputs, built as the evaluation pipeline builds them (ml-eye
/// `evaluation/package.py`, Pillow), so a photo scores here as it did in the
/// numbers the model shipped on:
///
/// - `photo_peak`: short side to 384 (bicubic), the centre 384x384;
/// - `spatial`: the whole frame squashed to 384x384 (bicubic);
/// - `faces_detect`: long side to 768 (bilinear), pasted top-left on grey 114;
/// - `faces_analyze`: a square 1.4x the face box (black outside the image), to 128 (bilinear);
/// - `sharp_<aspect>`: gray (ITU-R 601 luma), to the closest shape (Lanczos).
///
/// Every tensor is `(1, C, H, W)` float32 in `0...1`.
enum Preprocess {
    /// 8-bit pixels, interleaved, `channels` 1 or 3.
    struct Plane {
        let width: Int
        let height: Int
        let channels: Int
        var bytes: [UInt8]
    }

    static func rgb(_ image: ImagePixels) -> Plane {
        if image.channels == 3 { return Plane(width: image.width, height: image.height, channels: 3, bytes: image.bytes) }
        var out = [UInt8](repeating: 0, count: image.width * image.height * 3)
        for i in 0..<(image.width * image.height) {
            out[i * 3] = image.bytes[i * 4]
            out[i * 3 + 1] = image.bytes[i * 4 + 1]
            out[i * 3 + 2] = image.bytes[i * 4 + 2]
        }
        return Plane(width: image.width, height: image.height, channels: 3, bytes: out)
    }

    /// Python's `round`: half to even.
    static func pyRound(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }

    static func centreCrop(_ image: Plane, side: Int = 384) -> Plane {
        let s = Double(side) / Double(min(image.width, image.height))
        let w = max(side, pyRound(Double(image.width) * s)), h = max(side, pyRound(Double(image.height) * s))
        let r = resize(image, width: w, height: h, filter: .bicubic)
        return crop(r, x0: (w - side) / 2, y0: (h - side) / 2, width: side, height: side)
    }

    static func squash(_ image: Plane, side: Int = 384) -> Plane {
        resize(image, width: side, height: side, filter: .bicubic)
    }

    /// The letterboxed frame and the scale from image pixels to it.
    static func letterbox(_ image: Plane, side: Int = 768) -> (Plane, Double) {
        let s = Double(side) / Double(max(image.width, image.height))
        let r = resize(image, width: max(1, pyRound(Double(image.width) * s)),
                       height: max(1, pyRound(Double(image.height) * s)), filter: .bilinear)
        var out = Plane(width: side, height: side, channels: 3, bytes: [UInt8](repeating: 114, count: side * side * 3))
        for y in 0..<min(r.height, side) {
            let n = min(r.width, side) * 3
            out.bytes.replaceSubrange((y * side * 3)..<(y * side * 3 + n), with: r.bytes[(y * r.width * 3)..<(y * r.width * 3 + n)])
        }
        return (out, s)
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

    /// A window of the image; pixels outside it are black, as Pillow's `crop`.
    static func crop(_ image: Plane, x0: Int, y0: Int, width: Int, height: Int) -> Plane {
        let ch = image.channels
        var out = [UInt8](repeating: 0, count: width * height * ch)
        let sx0 = max(x0, 0), sx1 = min(x0 + width, image.width)
        guard sx1 > sx0 else { return Plane(width: width, height: height, channels: ch, bytes: out) }
        for y in 0..<height {
            let sy = y0 + y
            guard sy >= 0, sy < image.height else { continue }
            let src = (sy * image.width + sx0) * ch, dst = (y * width + (sx0 - x0)) * ch, n = (sx1 - sx0) * ch
            out.replaceSubrange(dst..<(dst + n), with: image.bytes[src..<(src + n)])
        }
        return Plane(width: width, height: height, channels: ch, bytes: out)
    }

    /// `(1, C, H, W)` float32 in `0...1`.
    static func tensor(_ image: Plane) -> Tensor {
        let hw = image.width * image.height, ch = image.channels
        var out = [Float](repeating: 0, count: hw * ch)
        for i in 0..<hw {
            for c in 0..<ch { out[c * hw + i] = Float(image.bytes[i * ch + c]) / 255 }
        }
        return Tensor(float32: out, shape: [1, ch, image.height, image.width])
    }

    // MARK: Pillow's resampler (libImaging/Resample.c), 8 bits per channel

    enum Filter {
        case bilinear, bicubic, lanczos

        var support: Double {
            switch self {
            case .bilinear: 1
            case .bicubic: 2
            case .lanczos: 3
            }
        }

        func callAsFunction(_ v: Double) -> Double {
            switch self {
            case .bilinear:
                let x = abs(v)
                return x < 1 ? 1 - x : 0
            case .bicubic:
                let a = -0.5, x = abs(v)
                if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
                if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
                return 0
            case .lanczos:
                func sinc(_ x: Double) -> Double { x == 0 ? 1 : Double.sin(x * .pi) / (x * .pi) }
                return (-3 <= v && v < 3) ? sinc(v) * sinc(v / 3) : 0
            }
        }
    }

    static let precisionBits = 32 - 8 - 2

    /// Fixed-point taps per output pixel: the first source index, the tap count,
    /// and `ksize` weights per pixel.
    struct Taps {
        var start: [Int]
        var count: [Int]
        var weights: [Int32]
        let ksize: Int
    }

    static func taps(inSize: Int, outSize: Int, filter: Filter) -> Taps {
        let scale = Double(inSize) / Double(outSize)
        let filterScale = max(scale, 1)
        let support = filter.support * filterScale
        let ksize = Int(support.rounded(.up)) * 2 + 1
        var t = Taps(start: [], count: [], weights: [Int32](repeating: 0, count: outSize * ksize), ksize: ksize)
        var k = [Double](repeating: 0, count: ksize)
        let ss = 1 / filterScale
        for xx in 0..<outSize {
            let center = (Double(xx) + 0.5) * scale
            let xmin = max(Int(center - support + 0.5), 0)
            let xmax = min(Int(center + support + 0.5), inSize) - xmin
            var total = 0.0
            for x in 0..<xmax {
                // Same operation order as Pillow, so the taps match to the bit.
                k[x] = filter((Double(x + xmin) - center + 0.5) * ss)
                total += k[x]
            }
            for x in 0..<xmax {
                let v = total != 0 ? k[x] / total : k[x]
                let fixed = v * Double(1 << precisionBits)
                t.weights[xx * ksize + x] = Int32(v < 0 ? fixed - 0.5 : fixed + 0.5)
            }
            t.start.append(xmin)
            t.count.append(max(xmax, 0))
        }
        return t
    }

    @inline(__always)
    static func clip8(_ v: Int32) -> UInt8 {
        let shifted = v >> Int32(precisionBits)
        return shifted <= 0 ? 0 : shifted >= 255 ? 255 : UInt8(shifted)
    }

    /// `image` resized to `width` x `height`, as Pillow's `Image.resize`: a
    /// horizontal pass over only the rows the vertical pass reads, each pass
    /// skipped when its size is unchanged, rounding to 8 bits between them.
    /// Integer sums, so the loop order and the split across threads leave every
    /// byte as Pillow's (EyeTests checks both against the plain port).
    static func resize(_ image: Plane, width: Int, height: Int, filter: Filter) -> Plane {
        if image.width == width && image.height == height { return image }
        let vertical = taps(inSize: image.height, outSize: height, filter: filter)
        guard image.width != width else { return resizeVertical(image, taps: vertical, height: height) }
        let horizontal = taps(inSize: image.width, outSize: width, filter: filter)
        let first = image.height != height ? vertical.start[0] : 0
        let last = image.height != height ? vertical.start[height - 1] + vertical.count[height - 1] : image.height
        let src = resizeHorizontal(image, taps: horizontal, width: width, rows: first..<last)
        if image.height == height { return src }
        var shifted = vertical
        shifted.start = vertical.start.map { $0 - first }
        return resizeVertical(src, taps: shifted, height: height)
    }

    private static func resizeHorizontal(_ image: Plane, taps t: Taps, width: Int, rows: Range<Int>) -> Plane {
        let ch = image.channels, inRow = image.width * ch, outRow = width * ch, ksize = t.ksize
        let half = Int32(1 << (precisionBits - 1))
        var out = [UInt8](repeating: 0, count: rows.count * outRow)
        image.bytes.withUnsafeBufferPointer { s in
        t.weights.withUnsafeBufferPointer { kk in
        t.start.withUnsafeBufferPointer { starts in
        t.count.withUnsafeBufferPointer { counts in
        out.withUnsafeMutableBufferPointer { o in
            let s = s.baseAddress!, kk = kk.baseAddress!, starts = starts.baseAddress!, counts = counts.baseAddress!
            let o = o.baseAddress!
            parallelChunks(rows.count, work: rows.count * outRow * ksize) { lo, hi in
                for r in lo..<hi {
                    let row = s + (rows.lowerBound + r) * inRow, dst = o + r * outRow
                    for xx in 0..<width {
                        let k = kk + xx * ksize, n = counts[xx], p = row + starts[xx] * ch
                        if ch == 3 {
                            var a0 = half, a1 = half, a2 = half
                            for x in 0..<n {
                                let w = k[x], q = p + x * 3
                                a0 &+= Int32(q[0]) &* w
                                a1 &+= Int32(q[1]) &* w
                                a2 &+= Int32(q[2]) &* w
                            }
                            dst[xx * 3] = clip8(a0)
                            dst[xx * 3 + 1] = clip8(a1)
                            dst[xx * 3 + 2] = clip8(a2)
                        } else {
                            for c in 0..<ch {
                                var a = half
                                for x in 0..<n { a &+= Int32(p[x * ch + c]) &* k[x] }
                                dst[xx * ch + c] = clip8(a)
                            }
                        }
                    }
                }
            }
        }}}}}
        return Plane(width: width, height: rows.count, channels: ch, bytes: out)
    }

    /// Each output row as a sum of whole input rows: contiguous, so it vectorizes.
    private static func resizeVertical(_ image: Plane, taps t: Taps, height: Int) -> Plane {
        let n = image.width * image.channels, ksize = t.ksize
        let half = Int32(1 << (precisionBits - 1))
        var out = [UInt8](repeating: 0, count: height * n)
        image.bytes.withUnsafeBufferPointer { s in
        t.weights.withUnsafeBufferPointer { kk in
        t.start.withUnsafeBufferPointer { starts in
        t.count.withUnsafeBufferPointer { counts in
        out.withUnsafeMutableBufferPointer { o in
            let s = s.baseAddress!, kk = kk.baseAddress!, starts = starts.baseAddress!, counts = counts.baseAddress!
            let o = o.baseAddress!
            parallelChunks(height, work: height * n * ksize) { lo, hi in
                let acc = UnsafeMutablePointer<Int32>.allocate(capacity: n)
                defer { acc.deallocate() }
                for yy in lo..<hi {
                    acc.initialize(repeating: half, count: n)
                    let k = kk + yy * ksize
                    for y in 0..<counts[yy] {
                        let w = k[y], row = s + (starts[yy] + y) * n
                        for i in 0..<n { acc[i] &+= Int32(row[i]) &* w }
                    }
                    let dst = o + yy * n
                    for i in 0..<n { dst[i] = clip8(acc[i]) }
                }
            }
        }}}}}
        return Plane(width: image.width, height: height, channels: image.channels, bytes: out)
    }

    /// `body(lo, hi)` over `0..<count` in chunks, on every core when the work is
    /// worth it. Inline where there are no threads (wasm).
    private static func parallelChunks(_ count: Int, work: Int, _ body: (Int, Int) -> Void) {
#if canImport(Dispatch) && !os(WASI)
        let chunks = min(count, work < 1 << 21 ? 1 : max(1, ProcessInfo.processInfo.activeProcessorCount) * 2)
        guard chunks > 1 else { return body(0, count) }
        // Each chunk writes its own rows of buffers that outlive this call.
        nonisolated(unsafe) let body = body
        DispatchQueue.concurrentPerform(iterations: chunks) { i in
            body(i * count / chunks, (i + 1) * count / chunks)
        }
#else
        body(0, count)
#endif
    }
}
