import SwiftUI
import Tongue

// One shared detector. Construction reads the 2 MB of bundled weights once; after
// that a detection is an int8 gather, a sum, one 59x32 matmul and a masked softmax,
// so it runs synchronously as you type. Nothing to await, nothing to download.
private let tongue = try? Tongue()

struct ContentView: View {

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    verdict
                    field
                    if let detection, !detection.candidates.isEmpty {
                        candidates(detection)
                    }
                    samples
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .navigationTitle("Tongue")
            .background(Color(.systemGroupedBackground))
            .onAppear { focused = true }
        }
    }

    @State private var text = ""
    @FocusState private var focused: Bool

    /// Recomputed on every keystroke, on the main thread, deliberately: showing
    /// that no debounce and no background queue are needed is half the point.
    /// `nil` while the field is empty — there is nothing to identify.
    private var detection: Detection? {
        guard let tongue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return tongue.detect(text)
    }

    private var verdict: some View {
        VStack(spacing: 6) {
            Text(headline)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .animation(.spring(response: 0.32, dampingFraction: 0.8), value: headline)

            if let subhead {
                Text(subhead)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 76)
        .padding(.top, 12)
    }

    /// Two names when the top pair is too close to separate. "la casa" is equally
    /// Italian and Spanish, and saying so beats crowning one at random.
    private var headline: String {
        guard tongue != nil else { return "Model failed to load" }
        guard let detection, let first = detection.candidates.first else { return "…" }
        if detection.isTooCloseToCall, detection.candidates.count > 1 {
            return "\(name(first.language)) or \(name(detection.candidates[1].language))"
        }
        return name(first.language)
    }

    private var subhead: String? {
        guard let detection, !detection.candidates.isEmpty else { return nil }
        let reliability: String
        switch detection.reliability {
        case .confident: reliability = "confident"
        case .likely: reliability = "likely"
        case .tentative: reliability = "too short to be sure"
        case .empty: return nil
        }
        let route: String
        switch detection.route.verdict {
        case .decisive: route = "script is decisive"
        case .narrowing: route = "script narrowed the field"
        case .ambiguous: route = "no script evidence"
        }
        return "\(reliability) · \(route)"
    }

    private var field: some View {
        TextField("Type in any language", text: $text, axis: .vertical)
            .focused($focused)
            .font(.system(size: 19, design: .rounded))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }

    private func candidates(_ detection: Detection) -> some View {
        VStack(spacing: 10) {
            ForEach(detection.candidates, id: \.language) { candidate in
                HStack(spacing: 12) {
                    Text(candidate.language)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)

                    Text(name(candidate.language))
                        .font(.system(size: 15))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: max(3, geometry.size.width * candidate.probability))
                        }
                    }
                    .frame(width: 84, height: 6)

                    Text(String(format: "%.0f%%", candidate.probability * 100))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: detection.candidates)
    }

    private var samples: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.5)

            ForEach(Self.examples, id: \.text) { example in
                Button {
                    text = example.text
                } label: {
                    HStack(spacing: 10) {
                        Text(example.text)
                            .font(.system(size: 15))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(example.note)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let examples: [(text: String, note: String)] = [
        ("je voudrais un café au lait", "French"),
        ("kann ich das haben", "German"),
        ("안녕하세요 만나서 반갑습니다", "script is decisive"),
        ("مرحبا كيف حالك اليوم", "script is decisive"),
        ("la casa", "a tie"),
        ("hi i am", "too short to be sure"),
    ]

    /// Foundation already knows every language name, localized to the reader.
    private func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }
}

#Preview {
    ContentView()
}
