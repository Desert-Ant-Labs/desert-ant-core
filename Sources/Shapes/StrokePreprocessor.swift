import RealModule

/// Converts one raw pen-down…pen-up stroke into the model's `[N, C]` feature
/// vectors. This is a 1:1 port of the Python reference (`preprocess.py`); the
/// algorithm is the cross-platform source of truth, so it is kept deliberately
/// simple and explicit. All math is done in `Double`; outputs are `Float`.
///
/// Pipeline:
///   1. Reject degenerate input + drop duplicate consecutive points.
///   2. Normalize position + scale (center; longer bbox side -> 1.0).
///   3. Arc-length resample at fixed spacing.
///   4. Per-point features `[dist, cos, sin]` (+ optional curvature).
///   5. Z-score the distance channel with frozen mean/std.
struct StrokePreprocessor {
    let config: PreprocessConfig

    init(config: PreprocessConfig = PreprocessConfig()) {
        self.config = config
    }

    // MARK: Public entry point

    /// Run the full pipeline on one stroke. Throws `DegenerateStrokeError` for
    /// input that is too short / too small.
    func process(points rawPoints: [Point]) throws -> [StrokePoint] {
        let cleaned = dedupeConsecutive(rawPoints)

        if cleaned.count < config.minPoints {
            throw DegenerateStrokeError(
                "stroke has \(cleaned.count) unique points (< \(config.minPoints))")
        }
        let total = totalLength(cleaned)
        if total < config.minTotalLength {
            throw DegenerateStrokeError(
                "stroke total length \(total) < \(config.minTotalLength)")
        }

        let normalized = normalize(cleaned)
        let resampled = resampleArcLength(normalized, spacing: config.spacing)
        return computeFeatures(resampled)
    }

    // MARK: Step 1 — dedupe + length

    private func dedupeConsecutive(_ points: [Point]) -> [Point] {
        guard let first = points.first else { return [] }
        var cleaned: [Point] = [Point(x: first.x, y: first.y)]
        let epsSq = config.dedupeEpsilon * config.dedupeEpsilon
        for i in 1..<Swift.max(points.count, 1) {
            let x = points[i].x
            let y = points[i].y
            let last = cleaned[cleaned.count - 1]
            let dx = x - last.x
            let dy = y - last.y
            if (dx * dx + dy * dy) > epsSq {
                cleaned.append(Point(x: x, y: y))
            }
        }
        return cleaned
    }

    private func totalLength(_ points: [Point]) -> Double {
        var total = 0.0
        if points.count < 2 { return 0.0 }
        for i in 1..<points.count {
            let dx = points[i].x - points[i - 1].x
            let dy = points[i].y - points[i - 1].y
            total += (dx * dx + dy * dy).squareRoot()
        }
        return total
    }

    // MARK: Step 2 — normalize position + scale

    private func normalize(_ points: [Point]) -> [Point] {
        guard let first = points.first else { return [] }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for p in points {
            if p.x < minX { minX = p.x }
            if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y }
            if p.y > maxY { maxY = p.y }
        }
        let width = maxX - minX
        let height = maxY - minY
        let centerX = (minX + maxX) * 0.5
        let centerY = (minY + maxY) * 0.5
        let longer = width > height ? width : height
        let scale = longer > 0.0 ? 1.0 / longer : 1.0

        var out: [Point] = []
        out.reserveCapacity(points.count)
        for p in points {
            out.append(Point(x: (p.x - centerX) * scale, y: (p.y - centerY) * scale))
        }
        return out
    }

    // MARK: Step 3 — arc-length resampling

    private func resampleArcLength(_ points: [Point], spacing: Double) -> [Point] {
        let n = points.count
        if n == 0 { return [] }
        if n == 1 { return [points[0]] }

        var resampled: [Point] = [points[0]]
        var prevX = points[0].x
        var prevY = points[0].y
        var distSinceLast = 0.0

        var i = 1
        while i < n {
            let curX = points[i].x
            let curY = points[i].y
            let segDx = curX - prevX
            let segDy = curY - prevY
            let segLen = (segDx * segDx + segDy * segDy).squareRoot()

            if segLen <= 0.0 {
                prevX = curX; prevY = curY
                i += 1
                continue
            }

            let needed = spacing - distSinceLast
            if needed <= segLen {
                let t = needed / segLen
                let nx = prevX + segDx * t
                let ny = prevY + segDy * t
                resampled.append(Point(x: nx, y: ny))
                prevX = nx; prevY = ny
                distSinceLast = 0.0
                // Do NOT advance i: more samples may fit in this segment.
            } else {
                distSinceLast += segLen
                prevX = curX; prevY = curY
                i += 1
            }
        }

        // Ensure the exact last point is present.
        let last = points[n - 1]
        let rLast = resampled[resampled.count - 1]
        let ddx = last.x - rLast.x
        let ddy = last.y - rLast.y
        if (ddx * ddx + ddy * ddy) > 1e-18 {
            resampled.append(last)
        }
        return resampled
    }

    // MARK: Steps 4 + 5 — features + distance normalization

    private func computeFeatures(_ points: [Point]) -> [StrokePoint] {
        let n = points.count
        let std = config.distStd > 0.0 ? config.distStd : 1.0
        var features: [StrokePoint] = []
        features.reserveCapacity(n)

        var prevTheta = 0.0
        var havePrevTheta = false

        for i in 0..<n {
            var dist = 0.0
            var cosT = 0.0
            var sinT = 0.0
            if i > 0 {
                let dx = points[i].x - points[i - 1].x
                let dy = points[i].y - points[i - 1].y
                dist = (dx * dx + dy * dy).squareRoot()
                if dist > 0.0 {
                    cosT = dx / dist
                    sinT = dy / dist
                }
            }
            let distNorm = (dist - config.distMean) / std

            var curvature = 0.0
            if config.addCurvature {
                if i > 0 && (cosT != 0.0 || sinT != 0.0) {
                    let theta = Double.atan2(y: sinT, x: cosT)
                    if havePrevTheta {
                        curvature = wrapPi(theta - prevTheta)
                    }
                    prevTheta = theta
                    havePrevTheta = true
                }
            }

            features.append(StrokePoint(
                distance: Float(distNorm),
                cosTheta: Float(cosT),
                sinTheta: Float(sinT),
                curvature: Float(curvature)))
        }
        return features
    }

    private func wrapPi(_ angle: Double) -> Double {
        let twoPi = 2.0 * Double.pi
        var a = angle.truncatingRemainder(dividingBy: twoPi)
        if a <= -Double.pi {
            a += twoPi
        } else if a > Double.pi {
            a -= twoPi
        }
        return a
    }
}
