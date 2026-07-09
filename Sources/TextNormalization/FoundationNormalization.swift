// NFKC via Foundation on Apple and Linux (both ship the native Swift Foundation
// SDK, whose ICU is already loaded, so nothing extra is linked).
#if canImport(Foundation) && !os(Android) && !os(WASI)
import Foundation

func nfkcNormalize(_ s: String) -> String { s.precomposedStringWithCompatibilityMapping }
#endif
