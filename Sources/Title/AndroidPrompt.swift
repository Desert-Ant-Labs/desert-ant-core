extension Titles {
    /// The text-only, single-user-message path of Granite's chat template.
    static func androidPrompt(_ passage: String) -> String {
        let instruction = prompt.replacing("{clip}", with: passage)
        return """
            <|start_of_role|>system<|end_of_role|>You are a helpful assistant. Please ensure responses are professional, accurate, and safe.<|end_of_text|>
            <|start_of_role|>user<|end_of_role|>\(instruction)<|end_of_text|>
            <|start_of_role|>assistant<|end_of_role|>
            """
    }

    static func fittedAndroidPrompt(
        _ passage: String, budget: Int, tokenCount: (String) throws -> Int
    ) throws -> String? {
        func render(_ prefix: Substring) -> String {
            // The counting API takes a C string, while prefill takes a byte count.
            androidPrompt(String(prefix).replacing("\0", with: "\u{FFFD}"))
        }

        var best = androidPrompt("")
        var lo = 0
        var hi = 512
        // Probe progressively so dense text reaches the token budget before we
        // pay to tokenize the rest of the passage.
        while true {
            let prefix = passage.prefix(hi)
            let candidate = render(prefix)
            if try tokenCount(candidate) > budget {
                hi = prefix.count
                break
            }
            if prefix.endIndex == passage.endIndex { return candidate }
            best = candidate
            lo = hi
            hi *= 2
        }
        if lo == 0, try tokenCount(best) > budget { return nil }

        while hi - lo > 1 {
            let mid = lo + (hi - lo) / 2
            let candidate = render(passage.prefix(mid))
            if try tokenCount(candidate) <= budget {
                lo = mid
                best = candidate
            } else {
                hi = mid
            }
        }
        return best
    }
}
