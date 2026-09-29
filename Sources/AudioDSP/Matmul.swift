// Row-major single-precision GEMM behind the STFT/mel matmuls: Accelerate on
// Apple (the point of doing STFT as a matmul is that it runs on the vector
// units), a portable loop everywhere else.

#if canImport(Accelerate)
import Accelerate
#endif

enum Matmul {
    /// `c[m x n] = alpha * a[m x k] @ b[k x n] + beta * c`, all row-major.
    static func gemm(_ a: [Float], _ b: [Float], into c: inout [Float],
                     m: Int, n: Int, k: Int, alpha: Float = 1, beta: Float = 0) {
        #if canImport(Accelerate)
        // vDSP_mmul, not cblas_sgemm: the classic CBLAS interface is deprecated
        // since macOS 13.3 behind -DACCELERATE_NEW_LAPACK, and a Clang define
        // needs unsafeFlags, which a package consumed as a dependency cannot
        // carry. vDSP runs on the same vector units and is not deprecated;
        // alpha/beta become one fused scale-and-add pass over c, negligible
        // next to the matmul itself.
        if beta == 0 {
            // Write c directly: stale c is dead when beta == 0, so no temp and
            // no read-back. A temp buffer measured 15% slower than fused cblas at
            // Ear's minute-of-audio sizes; this is within noise.
            vDSP_mmul(a, 1, b, 1, &c, 1, vDSP_Length(m), vDSP_Length(n), vDSP_Length(k))
            if alpha != 1 {
                var sa = alpha
                vDSP_vsmul(c, 1, &sa, &c, 1, vDSP_Length(m * n))
            }
        } else {
            var t = [Float](repeating: 0, count: m * n)
            vDSP_mmul(a, 1, b, 1, &t, 1, vDSP_Length(m), vDSP_Length(n), vDSP_Length(k))
            var sa = alpha, sb = beta
            // c = alpha * t + beta * c
            vDSP_vsmsma(t, 1, &sa, c, 1, &sb, &c, 1, vDSP_Length(m * n))
        }
        #else
        gemmPortable(a, b, into: &c, m: m, n: n, k: k, alpha: alpha, beta: beta)
        #endif
    }

    /// The non-Accelerate GEMM, same contract as `gemm`.
    static func gemmPortable(_ a: [Float], _ b: [Float], into c: inout [Float],
                             m: Int, n: Int, k: Int, alpha: Float = 1, beta: Float = 0) {
        // Row at a time for contiguous inner loops; each element sums its k products in order, as a triple loop does.
        guard m > 0, n > 0 else { return }
        guard k > 0 else {
            for idx in 0..<(m * n) { c[idx] = alpha * 0 + beta * c[idx] }
            return
        }
        var row = [Float](repeating: 0, count: n)
        a.withUnsafeBufferPointer { ap in b.withUnsafeBufferPointer { bp in
        c.withUnsafeMutableBufferPointer { cp in row.withUnsafeMutableBufferPointer { rp in
            let r = rp.baseAddress!
            for i in 0..<m {
                for j in 0..<n { r[j] = 0 }
                let aRow = ap.baseAddress! + i * k
                for p in 0..<k {
                    let av = aRow[p]
                    let bRow = bp.baseAddress! + p * n
                    for j in 0..<n { r[j] += av * bRow[j] }
                }
                let cRow = cp.baseAddress! + i * n
                for j in 0..<n { cRow[j] = alpha * r[j] + beta * cRow[j] }
            }
        } } } }
    }
}
