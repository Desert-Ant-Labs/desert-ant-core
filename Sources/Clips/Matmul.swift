// Single-precision GEMM behind the chapter head. Accelerate BLAS on Apple, a plain triple
// loop everywhere else. Same result either way, so the parity test against PyTorch passes on
// Linux and the Apple build still runs on the vector units.
//
// DELIBERATELY DUPLICATED from `AudioDSP/Matmul.swift`, which does the same job for the STFT
// and mel matmuls. Clips has no business importing an audio module to multiply matrices, and
// hoisting a shared numerics target would touch AudioDSP, Clear and Align to save twenty
// lines. If a third consumer appears, that is the moment to hoist it.
//
// WHY THIS EXISTS AT ALL. The chapter head shipped as scalar Swift on the argument that it was
// "microseconds next to the trunk pass". Measured at shipping geometry on an M3 Ultra it was
// 0.581 s at 400 sentences and 1.162 s at 800, against a ~2.4 s trunk pass, i.e. a quarter of
// the budget rather than a rounding error. See `ChapterModel` for the numbers.

import Foundation

#if canImport(Accelerate)
import Accelerate
#endif

enum Matmul {
    /// `c[m x n] = a[m x k] @ b[n x k]^T + bias`, row-major, B TRANSPOSED.
    ///
    /// The transposed form is the one that matters here: PyTorch stores `nn.Linear.weight` as
    /// `[out, in]` and computes `x @ W^T`, so taking B transposed lets the exported weights be
    /// used exactly as they were saved. Transposing them at load time instead would be a
    /// second representation of the same numbers and a second thing to get wrong.
    static func linear(_ a: [Float], weight: [Float], bias: [Float],
                       into c: inout [Float], m: Int, n: Int, k: Int) {
        precondition(a.count >= m * k && weight.count >= n * k && c.count >= m * n)
        // Broadcast the bias into C first, then accumulate with beta=1. BLAS has no bias
        // argument, and this is cheaper than a separate add pass over C afterwards.
        if bias.isEmpty {
            for i in 0..<(m * n) { c[i] = 0 }
        } else {
            precondition(bias.count >= n)
            c.withUnsafeMutableBufferPointer { out in
                bias.withUnsafeBufferPointer { b in
                    for row in 0..<m {
                        out.baseAddress!.advanced(by: row * n)
                            .update(from: b.baseAddress!, count: n)
                    }
                }
            }
        }
        #if canImport(Accelerate)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                    Int32(m), Int32(n), Int32(k), 1,
                    a, Int32(k), weight, Int32(k), 1, &c, Int32(n))
        #else
        a.withUnsafeBufferPointer { ap in
            weight.withUnsafeBufferPointer { wp in
                c.withUnsafeMutableBufferPointer { cp in
                    for i in 0..<m {
                        let aRow = ap.baseAddress! + i * k
                        for j in 0..<n {
                            let wRow = wp.baseAddress! + j * k
                            var acc: Float = 0
                            for p in 0..<k { acc += aRow[p] * wRow[p] }
                            cp[i * n + j] += acc
                        }
                    }
                }
            }
        }
        #endif
    }

    /// `c[m x n] = a[m x k] @ b[k x n]`, row-major, both untransposed.
    /// Used for the attention-weighted value sum, where V is already `[n, headDim]`.
    static func gemm(_ a: [Float], _ b: [Float], into c: inout [Float],
                     m: Int, n: Int, k: Int) {
        precondition(a.count >= m * k && b.count >= k * n && c.count >= m * n)
        #if canImport(Accelerate)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                    Int32(m), Int32(n), Int32(k), 1,
                    a, Int32(k), b, Int32(n), 0, &c, Int32(n))
        #else
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                c.withUnsafeMutableBufferPointer { cp in
                    for i in 0..<m {
                        let aRow = ap.baseAddress! + i * k
                        for j in 0..<n {
                            var acc: Float = 0
                            for p in 0..<k { acc += aRow[p] * bp[p * n + j] }
                            cp[i * n + j] = acc
                        }
                    }
                }
            }
        }
        #endif
    }

    /// `c[m x m] = a[m x k] @ a2[m x k]^T` scaled. The attention score matrix.
    static func scores(_ q: [Float], _ k: [Float], into c: inout [Float],
                       rows: Int, dim: Int, scale: Float) {
        precondition(c.count >= rows * rows)
        #if canImport(Accelerate)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                    Int32(rows), Int32(rows), Int32(dim), scale,
                    q, Int32(dim), k, Int32(dim), 0, &c, Int32(rows))
        #else
        q.withUnsafeBufferPointer { qp in
            k.withUnsafeBufferPointer { kp in
                c.withUnsafeMutableBufferPointer { cp in
                    for i in 0..<rows {
                        let qRow = qp.baseAddress! + i * dim
                        for j in 0..<rows {
                            let kRow = kp.baseAddress! + j * dim
                            var acc: Float = 0
                            for p in 0..<dim { acc += qRow[p] * kRow[p] }
                            cp[i * rows + j] = acc * scale
                        }
                    }
                }
            }
        }
        #endif
    }

    /// Row-wise softmax in place over `rows x cols`, max-subtracted.
    static func softmaxRows(_ x: inout [Float], rows: Int, cols: Int) {
        x.withUnsafeMutableBufferPointer { buf in
            for r in 0..<rows {
                let row = buf.baseAddress! + r * cols
                var maxValue: Float = -.greatestFiniteMagnitude
                #if canImport(Accelerate)
                vDSP_maxv(row, 1, &maxValue, vDSP_Length(cols))
                var negMax = -maxValue
                vDSP_vsadd(row, 1, &negMax, row, 1, vDSP_Length(cols))
                var count = Int32(cols)
                vvexpf(row, row, &count)
                var total: Float = 0
                vDSP_sve(row, 1, &total, vDSP_Length(cols))
                var inv = 1 / total
                vDSP_vsmul(row, 1, &inv, row, 1, vDSP_Length(cols))
                #else
                for i in 0..<cols { maxValue = max(maxValue, row[i]) }
                var total: Float = 0
                for i in 0..<cols { row[i] = exp(row[i] - maxValue); total += row[i] }
                let inv = 1 / total
                for i in 0..<cols { row[i] *= inv }
                #endif
            }
        }
    }

    /// GELU in place, tanh approximation, matching `activation="gelu"` as PyTorch's
    /// TransformerEncoderLayer applies it.
    static func gelu(_ x: inout [Float]) {
        x.withUnsafeMutableBufferPointer { buf in
            for i in 0..<buf.count {
                let v = buf[i]
                let inner = 0.7978845608 * (v + 0.044715 * v * v * v)
                buf[i] = 0.5 * v * (1 + tanh(inner))
            }
        }
    }

    /// LayerNorm over the last axis of `rows x cols`, in place.
    static func layerNormRows(_ x: inout [Float], rows: Int, cols: Int,
                              weight: [Float], bias: [Float], eps: Float = 1e-5) {
        x.withUnsafeMutableBufferPointer { buf in
            weight.withUnsafeBufferPointer { w in
                bias.withUnsafeBufferPointer { b in
                    for r in 0..<rows {
                        let row = buf.baseAddress! + r * cols
                        var mean: Float = 0
                        for i in 0..<cols { mean += row[i] }
                        mean /= Float(cols)
                        var variance: Float = 0
                        for i in 0..<cols {
                            let d = row[i] - mean
                            variance += d * d
                        }
                        variance /= Float(cols)
                        let inv = 1 / (variance + eps).squareRoot()
                        for i in 0..<cols {
                            row[i] = (row[i] - mean) * inv * w[i] + b[i]
                        }
                    }
                }
            }
        }
    }
}
