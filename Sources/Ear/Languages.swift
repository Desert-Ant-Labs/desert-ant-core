// The label space, and the one place a prediction is allowed to be overruled.

/// Codes the detector emits that differ from the ones callers expect.
let languageAliases: [String: String] = [
    "tl": "fil",   // Tagalog / Filipino
    "nb": "no",    // Bokmal / Norwegian
    "yue": "zh",   // Cantonese, folded into Chinese
]

/// Languages the detector confuses with each other often enough that an answer
/// naming one of them carries no information.
///
/// The detector reads Norwegian as Swedish in roughly 40% of clips. That is a
/// property of the network, not of the compression: it survives every build we
/// have measured, quantized or not, and no amount of extra audio fixes it
/// because the error is confident rather than uncertain.
///
/// ``Detection/isReliable`` is false for these, so a caller routing work on the
/// answer can decline to. Nothing is hidden: the language is still reported.
let confusableLanguages: Set<String> = ["no", "sv", "da"]

func canonicalLanguage(_ code: String) -> String {
    languageAliases[code] ?? code
}
