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
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                    Int32(m), Int32(n), Int32(k), alpha,
                    a, Int32(k), b, Int32(n), beta, &c, Int32(n))
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
