/// The crops the model scores, bit-exact with the evaluation pipeline
/// (moderator-training `fit_multiscale_tiles` + flips, Pillow `BILINEAR`), so an
/// image scores the same here as in the numbers the model was shipped on.
///
/// Tile 0 letterboxes the whole image onto a black square; tiles 1-3 are center
/// squares of 85%, 70% and 55% of the short side. `accurate` adds each tile's
/// mirror image. `fast` is a single center square of the full short side.
enum Preprocess {
    static let side = 384
    private static let zooms: [Double] = [0.85, 0.70, 0.55]

    /// Each crop as `side * side * 3` RGB bytes. The tiles are independent, so
    /// they resample in parallel; cancellation is checked between them.
    static func crops(_ image: ImagePixels, quality: Quality) async throws -> [[UInt8]] {
        let windows = self.windows(image, quality: quality)
        var tiles = [[UInt8]](repeating: [], count: windows.count)
        try await withThrowingTaskGroup(of: (Int, [UInt8]).self) { group in
            for (i, w) in windows.enumerated() {
                group.addTask {
                    try Task.checkCancellation()
                    return (i, resample(image, x0: w.x0, y0: w.y0, size: w.size))
                }
            }
            for try await (i, tile) in group { tiles[i] = tile }
        }
        guard quality == .accurate else { return tiles }
        return tiles.flatMap { [$0, mirrored($0)] }
    }

    /// The square source windows each crop is resampled from: tile 0 is the
    /// letterbox (a window larger than the image, black outside it).
    private static func windows(_ image: ImagePixels, quality: Quality) -> [(x0: Int, y0: Int, size: Int)] {
        let w = image.width, h = image.height, short = min(w, h)
        func square(_ s: Int) -> (x0: Int, y0: Int, size: Int) { ((w - s) / 2, (h - s) / 2, s) }
        if quality == .fast { return [square(short)] }
        let long = max(w, h)
        return [(-((long - w) / 2), -((long - h) / 2), long)] + zooms.map { square(Int(Double(short) * $0)) }
    }

    private static func mirrored(_ rgb: [UInt8]) -> [UInt8] {
        var out = rgb
        for y in 0..<side {
            let row = y * side * 3
            for x in 0..<side {
                let src = row + (side - 1 - x) * 3, dst = row + x * 3
                out[dst] = rgb[src]; out[dst + 1] = rgb[src + 1]; out[dst + 2] = rgb[src + 2]
            }
        }
        return out
    }

    // MARK: Pillow's two-pass resampler (libImaging/Resample.c), bilinear filter

    private static let precisionBits: Int32 = 32 - 8 - 2

    /// Fixed-point filter taps per output pixel: the first source index, the tap
    /// count, and `ksize` weights per pixel.
    private struct Taps {
        var start: [Int] = []
        var count: [Int] = []
        var weights: [Int32] = []
        let ksize: Int
    }

    private static func taps(inSize: Int, outSize: Int) -> Taps {
        let scale = Double(inSize) / Double(outSize)
        let filterScale = max(scale, 1)
        let support = filterScale  // bilinear support is 1
        let ss = 1 / filterScale
        let ksize = Int(support.rounded(.up)) * 2 + 1
        var t = Taps(ksize: ksize)
        t.weights = [Int32](repeating: 0, count: outSize * ksize)
        var k = [Double](repeating: 0, count: ksize)
        for xx in 0..<outSize {
            let center = (Double(xx) + 0.5) * scale
            let xmin = max(Int(center - support + 0.5), 0)
            let xmax = min(Int(center + support + 0.5), inSize) - xmin
            var total = 0.0
            for x in 0..<xmax {
                // Same operation order as Pillow, so the taps match to the bit.
                let d = abs((Double(x + xmin) - center + 0.5) * ss)
                k[x] = d < 1 ? 1 - d : 0
                total += k[x]
            }
            for x in 0..<xmax {
                let v = total != 0 ? k[x] / total : k[x]
                let fixed = v * Double(1 << precisionBits)
                t.weights[xx * ksize + x] = Int32(v < 0 ? fixed - 0.5 : fixed + 0.5)
            }
            t.start.append(xmin)
            t.count.append(xmax)
        }
        return t
    }

    @inline(__always)
    private static func clip8(_ v: Int32) -> UInt8 {
        let shifted = v >> precisionBits
        return shifted <= 0 ? 0 : shifted >= 255 ? 255 : UInt8(shifted)
    }

    /// The `size` x `size` window at (`x0`, `y0`) of `image`, resized to `side`.
    /// Pixels outside the image read as black, which is the letterbox.
    private static func resample(_ image: ImagePixels, x0: Int, y0: Int, size: Int) -> [UInt8] {
        let horizontal = taps(inSize: size, outSize: side)
        let vertical = taps(inSize: size, outSize: side)
        let rowFirst = vertical.start[0]
        let rowLast = vertical.start[side - 1] + vertical.count[side - 1]
        let rows = rowLast - rowFirst
        let half: Int32 = 1 << (precisionBits - 1)
        let ch = image.channels, w = image.width, h = image.height

        // Horizontal pass over only the window rows the vertical pass reads.
        var temp = [UInt8](repeating: 0, count: rows * side * 3)
        image.bytes.withUnsafeBufferPointer { src in
            horizontal.weights.withUnsafeBufferPointer { kk in
                temp.withUnsafeMutableBufferPointer { out in
                    for r in 0..<rows {
                        let sy = y0 + rowFirst + r
                        guard sy >= 0, sy < h else { continue }  // black rows stay 0
                        let rowBase = sy * w * ch
                        for xx in 0..<side {
                            var s0 = half, s1 = half, s2 = half
                            let k = xx * horizontal.ksize, first = horizontal.start[xx]
                            for x in 0..<horizontal.count[xx] {
                                let sx = x0 + first + x
                                guard sx >= 0, sx < w else { continue }
                                let p = rowBase + sx * ch, weight = kk[k + x]
                                s0 &+= Int32(src[p]) &* weight
                                s1 &+= Int32(src[p + 1]) &* weight
                                s2 &+= Int32(src[p + 2]) &* weight
                            }
                            let o = (r * side + xx) * 3
                            out[o] = clip8(s0); out[o + 1] = clip8(s1); out[o + 2] = clip8(s2)
                        }
                    }
                }
            }
        }

        var result = [UInt8](repeating: 0, count: side * side * 3)
        temp.withUnsafeBufferPointer { src in
            vertical.weights.withUnsafeBufferPointer { kk in
                result.withUnsafeMutableBufferPointer { out in
                    for yy in 0..<side {
                        let k = yy * vertical.ksize, first = vertical.start[yy] - rowFirst
                        for xx in 0..<side {
                            var s0 = half, s1 = half, s2 = half
                            for y in 0..<vertical.count[yy] {
                                let p = ((first + y) * side + xx) * 3, weight = kk[k + y]
                                s0 &+= Int32(src[p]) &* weight
                                s1 &+= Int32(src[p + 1]) &* weight
                                s2 &+= Int32(src[p + 2]) &* weight
                            }
                            let o = (yy * side + xx) * 3
                            out[o] = clip8(s0); out[o + 1] = clip8(s1); out[o + 2] = clip8(s2)
                        }
                    }
                }
            }
        }
        return result
    }
}
