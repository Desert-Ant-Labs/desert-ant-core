// Row-major single-precision GEMM behind the STFT/mel matmuls. Accelerate BLAS
// on Apple (the whole point of doing STFT as a matmul: it runs on the vector
// units); a plain triple loop everywhere else. Same result, so tests pass on
// Linux and the Apple SDK build still gets BLAS.

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
            // Write c directly; stale c is dead when beta == 0, so no temp and
            // no read-back. The in-place scale for alpha != 1 is one pass; at
            // Ear's minute-of-audio sizes the temp-buffer variant measured 15%
            // slower than fused cblas, this is back within noise.
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
        for i in 0..<m {
            for j in 0..<n {
                var acc: Float = 0
                let aRow = i * k
                for p in 0..<k { acc += a[aRow + p] * b[p * n + j] }
                let idx = i * n + j
                c[idx] = alpha * acc + beta * c[idx]
            }
        }
        #endif
    }
}
