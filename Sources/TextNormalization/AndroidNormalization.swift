// NFKC via the platform ICU on Android (`libicu.so`, NDK API 31+), so the
// pure-Swift library links no Foundation (which would add tens of megabytes of
// its own ICU). CAndroidICU binds the system headers.
#if os(Android)
import CAndroidICU

func nfkcNormalize(_ s: String) -> String {
    var status = U_ZERO_ERROR
    guard let normalizer = unorm2_getNFKCInstance(&status),
          status.rawValue <= U_ZERO_ERROR.rawValue else { return s }
    let source = Array(s.utf16)
    status = U_ZERO_ERROR
    let needed = source.withUnsafeBufferPointer { src in
        unorm2_normalize(normalizer, src.baseAddress, Int32(src.count), nil, 0, &status)
    }
    guard needed >= 0 else { return s }
    var dest = [UInt16](repeating: 0, count: Int(needed))
    status = U_ZERO_ERROR
    let written = source.withUnsafeBufferPointer { src in
        dest.withUnsafeMutableBufferPointer { out in
            unorm2_normalize(normalizer, src.baseAddress, Int32(src.count), out.baseAddress, needed, &status)
        }
    }
    guard written >= 0, status.rawValue <= U_ZERO_ERROR.rawValue else { return s }
    return String(decoding: dest.prefix(Int(written)), as: UTF16.self)
}
#endif
