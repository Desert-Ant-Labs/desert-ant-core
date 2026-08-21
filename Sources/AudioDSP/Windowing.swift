// Analysis windows and the padding helpers STFT pipelines share. Pure Swift,
// so every platform gets the same coefficients (an STFT/ISTFT pair only
// reconstructs cleanly when both ends agree on the window to the last bit).

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(WASILibc)
import WASILibc
#elseif os(Windows)
import CRT
#endif

public enum Window {
    /// A Hann window of `count` samples: `0.5 - 0.5 cos(2 pi k / d)` where `d`
    /// is `count` for the periodic window (the DFT/STFT default, matching
    /// PyTorch/librosa `periodic=True`) or `count - 1` for the symmetric one.
    public static func hann(_ count: Int, periodic: Bool = true) -> [Float] {
        guard count > 1 else { return [Float](repeating: 1, count: max(0, count)) }
        let d = Float(periodic ? count : count - 1)
        var w = [Float](repeating: 0, count: count)
        for k in 0..<count { w[k] = 0.5 - 0.5 * cosf(2 * .pi * Float(k) / d) }
        return w
    }
}

public enum Padding {
    /// Reflect-pad `x` by `pad` samples on each side (no edge-sample repeat),
    /// matching `torch.stft(center=True)` / librosa `pad_mode="reflect"`. Used
    /// to center STFT frames so the first/last hop are not truncated.
    public static func reflect(_ x: [Float], pad: Int) -> [Float] {
        guard pad > 0, !x.isEmpty else { return x }
        var out = [Float](); out.reserveCapacity(x.count + 2 * pad)
        for i in 0..<pad { out.append(x[min(pad - i, x.count - 1)]) }
        out.append(contentsOf: x)
        for i in 0..<pad { out.append(x[max(x.count - 2 - i, 0)]) }
        return out
    }
}
