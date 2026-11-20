#if canImport(Accelerate)
import Accelerate
#endif
#if canImport(Dispatch)
import Dispatch
#endif

enum Cluster {
    static let firstPass: Float = 0.475
    static let secondPass: Float = 0.425

    struct Seed {
        var faces: [Int]
        var person: Int? = nil
        var rejected: Set<Int> = []
        /// Photos the seed's person is in outside these faces (their faces of another embedder): no face of these
        /// photos joins the seed.
        var occupied: Set<Int32> = []
    }

    static func group(_ emb: [[Float]], photos: [Int32], seeds: [Seed]? = nil) -> [Int] {
        let n = emb.count
        guard n > 0 else { return [] }
        let start = seeds ?? (0..<n).map { Seed(faces: [$0]) }
        var g = Groups(emb, photos: photos, seeds: start)
        g.run(threshold: firstPass, means: false)
        g.run(threshold: secondPass, means: true)
        var label = [Int](repeating: 0, count: n)
        for (k, seed) in start.enumerated() {
            let r = g.root(k)
            for i in seed.faces { label[i] = r }
        }
        return label
    }

    struct Groups {
        let d: Int
        var sums: [[Float]]
        var counts: [Float]
        var photos: [Set<Int32>]
        var person: [Int?]
        var rejected: [Set<Int>]
        var parent: [Int]
        var alive: [Int]

        init(_ emb: [[Float]], photos face: [Int32], seeds: [Seed]) {
            d = emb[0].count
            sums = seeds.map { s in
                var v = [Float](repeating: 0, count: emb[0].count)
                for i in s.faces { for k in v.indices { v[k] += emb[i][k] } }
                return v
            }
            counts = seeds.map { Float($0.faces.count) }
            photos = seeds.map { Set($0.faces.map { face[$0] }).union($0.occupied) }
            person = seeds.map(\.person)
            rejected = seeds.map(\.rejected)
            parent = Array(seeds.indices)
            alive = Array(seeds.indices)
        }

        func root(_ k: Int) -> Int {
            var r = k
            while parent[r] != r { r = parent[r] }
            return r
        }

        func compatible(_ a: Int, _ b: Int) -> Bool {
            if let p = person[a], let q = person[b], p != q { return false }
            if let p = person[a], rejected[b].contains(p) { return false }
            if let q = person[b], rejected[a].contains(q) { return false }
            return true
        }

        mutating func run(threshold: Float, means: Bool) {
            let minSim = 1 - threshold
            while alive.count > 1 {
                let m = alive.count
                var a = [Float](repeating: 0, count: m * d)
                var scale: [Float]? = means ? nil : [Float](repeating: 0, count: m)
                for (r, g) in alive.enumerated() {
                    let inv: Float
                    if means {
                        let norm = sums[g].reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
                        inv = 1 / max(norm, 1e-6)
                    } else {
                        inv = 1
                        scale![r] = 1 / counts[g]
                    }
                    for k in 0..<d { a[r * d + k] = sums[g][k] * inv }
                }
                let live = alive
                let best = Cluster.nearest(a, m: m, d: d, minSim: minSim, scale: scale, tries: means ? 8 : 16) { i, j in
                    let gi = live[i], gj = live[j]
                    // Two faces of one photo are never one person, in either pass.
                    return compatible(gi, gj) && photos[gi].isDisjoint(with: photos[gj])
                }
                var gone = Set<Int>()
                for i in 0..<m where best[i] > i && best[best[i]] == i {
                    merge(live[i], live[best[i]])
                    gone.insert(live[best[i]])
                }
                if gone.isEmpty { break }
                alive.removeAll { gone.contains($0) }
            }
        }

        mutating func merge(_ gi: Int, _ gj: Int) {
            for k in 0..<d { sums[gi][k] += sums[gj][k] }
            counts[gi] += counts[gj]
            photos[gi].formUnion(photos[gj])
            photos[gj] = []
            person[gi] = person[gi] ?? person[gj]
            rejected[gi].formUnion(rejected[gj])
            parent[gj] = gi
        }
    }

    @TaskLocal static var portable = false

    static func nearest(_ a: [Float], m: Int, d: Int, minSim: Float, scale: [Float]?, tries: Int,
                        allowed: (Int, Int) -> Bool) -> [Int] {
        var best = [Int](repeating: -1, count: m)
        let block = 256
        var g = [Float](repeating: 0, count: block * m)
        let fast = accelerated && !portable
        var at: [Float] = []
        if fast {
            at = [Float](repeating: 0, count: m * d)
            for i in 0..<m { for k in 0..<d { at[k * m + i] = a[i * d + k] } }
        }
        for r0 in stride(from: 0, to: m, by: block) {
            let rows = min(block, m - r0)
            if fast { gemm(a, at, r0: r0, rows: rows, m: m, d: d, into: &g) } else {
                gemmPortable(a, r0: r0, rows: rows, m: m, d: d, into: &g)
            }
            for r in 0..<rows {
                let i = r0 + r
                var row = Array(g[(r * m)..<(r * m + m)])
                if let s = scale { for j in 0..<m { row[j] *= s[i] * s[j] } }
                row[i] = -.infinity
                for _ in 0..<tries {
                    let (v, j) = fast ? argmax(row) : argmaxPortable(row)
                    if j < 0 || v < minSim { break }
                    if allowed(i, j) { best[i] = j; break }
                    row[j] = -.infinity
                }
            }
        }
        return best
    }

#if canImport(Accelerate)
    static let accelerated = true

    static func argmax(_ row: [Float]) -> (Float, Int) {
        var v: Float = 0
        var idx: vDSP_Length = 0
        vDSP_maxvi(row, 1, &v, &idx, vDSP_Length(row.count))
        return v == -.infinity ? (v, -1) : (v, Int(idx))
    }

    static func gemm(_ a: [Float], _ at: [Float], r0: Int, rows: Int, m: Int, d: Int, into out: inout [Float]) {
        a.withUnsafeBufferPointer { ap in
            out.withUnsafeMutableBufferPointer { gp in
                vDSP_mmul(ap.baseAddress! + r0 * d, 1, at, 1, gp.baseAddress!, 1,
                          vDSP_Length(rows), vDSP_Length(m), vDSP_Length(d))
            }
        }
    }
#else
    static let accelerated = false

    static func argmax(_ row: [Float]) -> (Float, Int) { argmaxPortable(row) }

    static func gemm(_ a: [Float], _ at: [Float], r0: Int, rows: Int, m: Int, d: Int, into out: inout [Float]) {
        gemmPortable(a, r0: r0, rows: rows, m: m, d: d, into: &out)
    }
#endif

    static func argmaxPortable(_ row: [Float]) -> (Float, Int) {
        var v = -Float.infinity, j = -1
        row.withUnsafeBufferPointer { p in
            for k in 0..<p.count where p[k] > v {
                v = p[k]
                j = k
            }
        }
        return (v, j)
    }

    static func gemmPortable(_ a: [Float], r0: Int, rows: Int, m: Int, d: Int, into out: inout [Float]) {
        a.withUnsafeBufferPointer { ap in
            out.withUnsafeMutableBufferPointer { op in
                nonisolated(unsafe) let src = ap.baseAddress!
                nonisolated(unsafe) let dst = op.baseAddress!
                let row: @Sendable (Int) -> Void = { r in
                    let x = src + (r0 + r) * d
                    for j in 0..<m {
                        let y = src + j * d
                        var s0: Float = 0, s1: Float = 0, s2: Float = 0, s3: Float = 0
                        var k = 0
                        while k + 4 <= d {
                            s0 += x[k] * y[k]
                            s1 += x[k + 1] * y[k + 1]
                            s2 += x[k + 2] * y[k + 2]
                            s3 += x[k + 3] * y[k + 3]
                            k += 4
                        }
                        while k < d {
                            s0 += x[k] * y[k]
                            k += 1
                        }
                        dst[r * m + j] = (s0 + s1) + (s2 + s3)
                    }
                }
#if canImport(Dispatch) && !os(WASI)
                DispatchQueue.concurrentPerform(iterations: rows, execute: row)
#else
                for r in 0..<rows { row(r) }
#endif
            }
        }
    }
}
