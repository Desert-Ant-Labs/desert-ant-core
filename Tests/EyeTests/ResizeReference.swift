@testable import Eye

/// The plain port of Pillow's resampler the optimized one replaced: one thread,
/// the loop order of libImaging/Resample.c. EyeTests holds the two to the byte.
extension Preprocess {
    /// `image` resized to `width` x `height`, as Pillow's `Image.resize`: a
    /// horizontal pass over only the rows the vertical pass reads, each pass
    /// skipped when its size is unchanged, rounding to 8 bits between them.
    static func referenceResize(_ image: Plane, width: Int, height: Int, filter: Filter) -> Plane {
        if image.width == width && image.height == height { return image }
        let ch = image.channels
        let half = Int32(1 << (precisionBits - 1))
        let vertical = taps(inSize: image.height, outSize: height, filter: filter)
        var src = image
        if image.width != width {
            let horizontal = taps(inSize: image.width, outSize: width, filter: filter)
            // Only the rows the vertical pass reads (all of them when it does not run).
            let first = image.height != height ? vertical.start[0] : 0
            let last = image.height != height ? vertical.start[height - 1] + vertical.count[height - 1] : image.height
            var out = [UInt8](repeating: 0, count: (last - first) * width * ch)
            image.bytes.withUnsafeBufferPointer { s in
                horizontal.weights.withUnsafeBufferPointer { kk in
                    out.withUnsafeMutableBufferPointer { o in
                        for r in 0..<(last - first) {
                            let row = (first + r) * image.width * ch
                            for xx in 0..<width {
                                let k = xx * horizontal.ksize, x0 = horizontal.start[xx]
                                for c in 0..<ch {
                                    var acc = half
                                    for x in 0..<horizontal.count[xx] {
                                        acc &+= Int32(s[row + (x0 + x) * ch + c]) &* kk[k + x]
                                    }
                                    o[(r * width + xx) * ch + c] = clip8(acc)
                                }
                            }
                        }
                    }
                }
            }
            src = Plane(width: width, height: last - first, channels: ch, bytes: out)
            if image.height == height { return src }
            var shifted = vertical
            shifted.start = vertical.start.map { $0 - first }
            return referenceVertical(src, taps: shifted, height: height)
        }
        return referenceVertical(src, taps: vertical, height: height)
    }

    static func referenceVertical(_ image: Plane, taps t: Taps, height: Int) -> Plane {
        let ch = image.channels, w = image.width
        let half = Int32(1 << (precisionBits - 1))
        var out = [UInt8](repeating: 0, count: height * w * ch)
        image.bytes.withUnsafeBufferPointer { s in
            t.weights.withUnsafeBufferPointer { kk in
                out.withUnsafeMutableBufferPointer { o in
                    for yy in 0..<height {
                        let k = yy * t.ksize, y0 = t.start[yy]
                        for i in 0..<(w * ch) {
                            var acc = half
                            for y in 0..<t.count[yy] {
                                acc &+= Int32(s[(y0 + y) * w * ch + i]) &* kk[k + y]
                            }
                            o[yy * w * ch + i] = clip8(acc)
                        }
                    }
                }
            }
        }
        return Plane(width: w, height: height, channels: ch, bytes: out)
    }
}
