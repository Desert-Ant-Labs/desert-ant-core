import DesertAnt
#if canImport(Dispatch) && !os(WASI)
import Dispatch
#if os(Android)
// Do not import Foundation on Android: it pulls in the full ICU payload.
// Use FoundationEssentials to keep ICU out of the SDK.
import FoundationEssentials
#else
import Foundation
#endif
#endif
import RealModule

/// The image operations Face's and Eye's model inputs are built from, each as Pillow does it, so a photo reaches
/// the models here as it did in the evaluation that measured them. Shared by both packages.
package enum Pillow {
    /// 8-bit pixels, interleaved, `channels` 1 or 3.
    package struct Plane {
        package let width: Int
        package let height: Int
        package let channels: Int
        package var bytes: [UInt8]

        package init(width: Int, height: Int, channels: Int, bytes: [UInt8]) {
            self.width = width
            self.height = height
            self.channels = channels
            self.bytes = bytes
        }
    }

    package static func rgb(_ image: ImagePixels) -> Plane {
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
    package static func pyRound(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }

    /// A window of the image; pixels outside it are black, as Pillow's `crop`.
    package static func crop(_ image: Plane, x0: Int, y0: Int, width: Int, height: Int) -> Plane {
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
    package static func tensor(_ image: Plane) -> Tensor {
        let hw = image.width * image.height, ch = image.channels
        var out = [Float](repeating: 0, count: hw * ch)
        for i in 0..<hw {
            for c in 0..<ch { out[c * hw + i] = Float(image.bytes[i * ch + c]) / 255 }
        }
        return Tensor(float32: out, shape: [1, ch, image.height, image.width])
    }

    // MARK: Pillow's resampler (libImaging/Resample.c), 8 bits per channel

    package enum Filter {
        case bilinear, bicubic, lanczos

        package var support: Double {
            switch self {
            case .bilinear: 1
            case .bicubic: 2
            case .lanczos: 3
            }
        }

        package func callAsFunction(_ v: Double) -> Double {
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

    package static let precisionBits = 32 - 8 - 2

    /// Fixed-point taps per output pixel: the first source index, the tap count,
    /// and `ksize` weights per pixel.
    package struct Taps {
        package var start: [Int]
        package var count: [Int]
        package var weights: [Int32]
        package let ksize: Int
    }

    package static func taps(inSize: Int, outSize: Int, filter: Filter) -> Taps {
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
    package static func clip8(_ v: Int32) -> UInt8 {
        let shifted = v >> Int32(precisionBits)
        return shifted <= 0 ? 0 : shifted >= 255 ? 255 : UInt8(shifted)
    }

    /// `image` resized to `width` x `height`, as Pillow's `Image.resize`: a
    /// horizontal pass over only the rows the vertical pass reads, each pass
    /// skipped when its size is unchanged, rounding to 8 bits between them.
    /// Integer sums, so the loop order and the split across threads leave every
    /// byte as Pillow's (EyeTests checks it against the plain port).
    package static func resize(_ image: Plane, width: Int, height: Int, filter: Filter) -> Plane {
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
