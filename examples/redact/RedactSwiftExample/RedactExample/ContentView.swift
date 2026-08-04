import Redact
import SwiftUI

// A tiny on-device PII demo, mirroring the web demo: pick a sample or type your
// own text, and Redact highlights or masks the personal data it finds. Nothing
// leaves the device. Everything below is UI. The whole SDK surface used here is
// `Redact()` and `redaction(of:)`.

struct ContentView: View {
    private enum ViewMode: String, CaseIterable, Identifiable {
        case highlight = "Highlight", redacted = "Redacted"
        var id: Self { self }
    }

    // Same five preview texts as the web demo: chat, a support ticket, a
    // Latin/Cyrillic/Greek mix, a form, and structured IDs.
    private static let samples: [(name: String, text: String)] = [
        ("Chat", "Hey, it's Anna Kovács, call me on +36 30 123 4567 or email anna.kovacs@example.hu. My IBAN is GB29 NWBK 6016 1331 9268 19 for the refund."),
        ("Ticket", "Customer: Dr. José-María O'Brien. Address: 123 Main Street, Apt 4B, München 80331. Card 4111 1111 1111 1111 was charged twice."),
        ("Multilingual", "Меня зовут Иван Петров, тел. +7 495 123-45-67. Παρακαλώ καλέστε τον Γιώργο Παπαδόπουλο. Mein Name ist Klaus Müller."),
        ("Form", "Full name: Sofia Rossi\nEmail: sofia.rossi@posteo.it\nPhone: 06 1234 5678\nSSN: 123-45-6789\nAddress: Via Roma 15, 00184 Roma"),
        ("IDs", "Please visit https://acme.io/login from server IP 192.168.1.42. Contact dev@acme.io. Routing number 021000021 for the ACH wire."),
    ]

    @State private var input = samples[0].text
    @State private var activeSample = 0
    @State private var mode: ViewMode = .highlight
    @State private var items: [Redaction.Item] = []
    @State private var scanned = ""          // the exact text `items` ranges belong to
    @State private var status = "Loading model…"
    @State private var statusIsError = false
    @State private var scanTask: Task<Void, Never>?

    private let redact = Redact()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    samplePicker
                    editor
                    Picker("View", selection: $mode) {
                        ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    statusLine
                    resultCard
                    legend
                }
                .padding()
            }
            .navigationTitle("Redact")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .task { await scanNow() }        // first scan once the view appears
        .onChange(of: input) { schedule() }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("On-device PII redaction")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            Text("Names, addresses, emails, phones, cards, IBANs and IDs, masked on device, across all 24 EU languages. Your text never leaves the phone.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var samplePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(Self.samples.enumerated()), id: \.offset) { i, sample in
                    Button(sample.name) {
                        activeSample = i
                        input = sample.text
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(activeSample == i ? Color.accentColor : Color(.secondarySystemBackground),
                                in: Capsule())
                    .foregroundStyle(activeSample == i ? Color.white : .primary)
                }
            }
        }
    }

    private var editor: some View {
        TextEditor(text: $input)
            .font(.body.monospaced())
            .frame(minHeight: 130)
            .padding(8)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private var statusLine: some View {
        Text(status)
            .font(.footnote)
            .foregroundStyle(statusIsError ? Color.red : .secondary)
    }

    private var resultCard: some View {
        Group {
            if items.isEmpty {
                Text(input.isEmpty ? "Detected entities will appear here." : "No personal data detected.")
                    .foregroundStyle(.secondary)
            } else if mode == .highlight {
                Text(highlighted).textSelection(.enabled)
            } else {
                Text(redactedText).textSelection(.enabled)
            }
        }
        .font(.body.monospaced())
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(Category.allCases) { cat in
                HStack(spacing: 5) {
                    Circle().fill(cat.color).frame(width: 9, height: 9)
                    Text(cat.title).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Rendering

    private var highlighted: AttributedString {
        var attr = AttributedString(scanned)
        for item in items {
            guard let lo = AttributedString.Index(item.range.lowerBound, within: attr),
                  let hi = AttributedString.Index(item.range.upperBound, within: attr) else { continue }
            let color = Category(item).color
            attr[lo..<hi].backgroundColor = color.opacity(0.18)
            attr[lo..<hi].foregroundColor = color
        }
        return attr
    }

    private var redactedText: AttributedString {
        var out = AttributedString()
        var cursor = scanned.startIndex
        for item in items where item.range.lowerBound >= cursor {
            out += AttributedString(String(scanned[cursor..<item.range.lowerBound]))
            var chip = AttributedString("[\(item.label.rawValue)]")
            let color = Category(item).color
            chip.foregroundColor = color
            chip.backgroundColor = color.opacity(0.18)
            out += chip
            cursor = item.range.upperBound
        }
        out += AttributedString(String(scanned[cursor...]))
        return out
    }

    // MARK: Scanning (debounced, cancels superseded runs)

    private func schedule() {
        activeSample = Self.samples.firstIndex { $0.text == input } ?? -1
        items = []                       // drop stale highlights so they never map onto new text
        scanTask?.cancel()
        scanTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            if Task.isCancelled { return }
            await scanNow()
        }
    }

    private func scanNow() async {
        let text = input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            items = []; status = "Ready."; return
        }
        status = "Scanning…"
        let start = Date()
        do {
            let r = try await redact.redaction(of: text)
            if Task.isCancelled { return }
            scanned = text          // set together with items so ranges always match the text
            items = r.items
            let ms = Int((Date().timeIntervalSince(start) * 1000).rounded())
            let noun = r.items.count == 1 ? "entity" : "entities"
            status = "\(r.items.count) \(noun) · \(ms) ms · on device"
            statusIsError = false
        } catch {
            items = []; status = "Detection failed."; statusIsError = true
        }
    }
}

// MARK: - Category palette (mirrors the web demo's colors)

private enum Category: String, CaseIterable, Identifiable {
    case name, contact, finance, id, address
    var id: Self { self }

    init(_ item: Redaction.Item) {
        switch item.label {
        case .givenName, .surname: self = .name
        case .email, .phone, .url, .ipAddress: self = .contact
        case .creditCard, .bankAccount, .routingNumber, .taxID, .ssn: self = .finance
        case .governmentID, .passport, .driversLicense: self = .id
        case .streetName, .buildingNumber, .secondaryAddress, .city, .state, .zipCode: self = .address
        }
    }

    var title: String {
        switch self {
        case .name: "Name"; case .contact: "Contact"; case .finance: "Finance"
        case .id: "ID"; case .address: "Address"
        }
    }

    var color: Color {
        switch self {
        case .name: Color(red: 0.114, green: 0.306, blue: 0.847)   // #1d4ed8
        case .contact: Color(red: 0.059, green: 0.463, blue: 0.431) // #0f766e
        case .finance: Color(red: 0.706, green: 0.325, blue: 0.035) // #b45309
        case .id: Color(red: 0.725, green: 0.110, blue: 0.110)      // #b91c1c
        case .address: Color(red: 0.486, green: 0.227, blue: 0.929) // #7c3aed
        }
    }
}

#Preview {
    ContentView()
}
