extension ImagePixels {
    /// The pixels made upright for an EXIF orientation (1...8). Cheaper than
    /// asking ImageIO for a transformed decode, which resamples the whole image.
    func oriented(exif orientation: Int) -> ImagePixels {
        guard (2...8).contains(orientation) else { return self }
        let w = width, h = height, ch = channels
        let swaps = orientation >= 5
        let outW = swaps ? h : w, outH = swaps ? w : h
        var out = [UInt8](repeating: 0, count: bytes.count)
        bytes.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<outH {
                    for x in 0..<outW {
                        let (sx, sy): (Int, Int)
                        switch orientation {
                        case 2: (sx, sy) = (w - 1 - x, y)
                        case 3: (sx, sy) = (w - 1 - x, h - 1 - y)
                        case 4: (sx, sy) = (x, h - 1 - y)
                        case 5: (sx, sy) = (y, x)
                        case 6: (sx, sy) = (y, h - 1 - x)
                        case 7: (sx, sy) = (w - 1 - y, h - 1 - x)
                        default: (sx, sy) = (w - 1 - y, x)  // 8
                        }
                        let s = (sy * w + sx) * ch, d = (y * outW + x) * ch
                        for c in 0..<ch { dst[d + c] = src[s + c] }
                    }
                }
            }
        }
        return try! ImagePixels(width: outW, height: outH, channels: ch, bytes: out)
    }
}
