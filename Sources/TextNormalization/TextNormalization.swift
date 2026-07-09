// Unicode normalization as a cross-platform primitive. Text models normalize
// before tokenizing (SentencePiece/XLM-R expect NFKC), and each platform
// already ships a normalizer, so this exposes one native-feeling API over the
// platform's own: no ICU is bundled where the OS or host already provides it.
//
//   Apple / Linux : Foundation's precomposedStringWithCompatibilityMapping
//   Android       : the platform ICU (unorm2, via CAndroidICU / libicu, API 31+)
//   WebAssembly   : the JS host's String.prototype.normalize('NFKC')
//
// Model-agnostic and reusable across projects. Exactly one backend file (in
// this module) is compiled per platform; each provides `nfkcNormalize`.

public extension String {
    /// This string under Unicode Normalization Form KC (compatibility
    /// decomposition, then canonical composition), using the platform's own
    /// normalizer. Idempotent; returns the input unchanged if normalization is
    /// unavailable.
    var nfkc: String { nfkcNormalize(self) }
}
