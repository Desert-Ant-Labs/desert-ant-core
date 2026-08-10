import SwiftUI
import UniformTypeIdentifiers
import Uhm

// A tiny on-device filler-word demo: pick an audio file and Uhm lists every
// "uh", "um", "hmm" it finds, with timestamps and confidence. Nothing leaves
// the device. Everything below is UI. The whole SDK surface used here is
// `Uhm()` and `analyze(audioURL:)` - the first run downloads the model once
// and caches it; later runs are offline.

struct ContentView: View {
    private enum Phase: Equatable {
        case idle, analyzing(Double), results, failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var picking = false
    @State private var fillers: [Uhm.Detection] = []
    @State private var audioDuration: Double = 0
    @State private var fileName = ""
    @State private var analyzeTask: Task<Void, Never>?

    private let uhm = Uhm()

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .idle: idleView
                case .analyzing(let fraction): busyView(fraction)
                case .results: resultsView
                case .failed(let message): failedView(message)
                }
            }
            .navigationTitle("Uhm")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Pick audio", systemImage: "waveform") { picking = true }
                        .disabled(isBusy)
                }
            }
            .fileImporter(isPresented: $picking,
                          allowedContentTypes: [.audio],
                          allowsMultipleSelection: false) { result in
                if case let .success(urls) = result, let url = urls.first {
                    analyze(url)
                }
            }
        }
    }

    private var isBusy: Bool {
        if case .analyzing = phase { return true }
        return false
    }

    // MARK: Sections

    private var idleView: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .opacity(0.5)
            Text("Pick an audio file to find filler words")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text("\"uh\", \"um\", \"hmm\" - found on device, one prediction every 20 ms. The first run downloads the model (~45 MB) and caches it.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding()
    }

    private func busyView(_ fraction: Double) -> some View {
        VStack(spacing: 16) {
            if fraction > 0 {
                ProgressView(value: fraction)
                    .frame(maxWidth: 220)
                Text("Analyzing… \(Int(fraction * 100))%")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text("Loading model…")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var resultsView: some View {
        List {
            Section {
                if fillers.isEmpty {
                    Text("No fillers detected.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(fillers.enumerated()), id: \.offset) { _, f in
                        HStack {
                            Text(f.type.map { "\($0)" } ?? "filler")
                                .font(.system(.body, design: .rounded).weight(.medium))
                            Spacer()
                            Text("\(Int(f.confidence * 100))%")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(timecode(f.start))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("\(fileName) · \(fillers.count) filler\(fillers.count == 1 ? "" : "s") · \(timecode(audioDuration)) of audio")
            }
        }
    }

    // MARK: Analysis

    private func analyze(_ url: URL) {
        analyzeTask?.cancel()
        phase = .analyzing(0)
        fileName = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        analyzeTask = Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let result = try await uhm.analyze(audioURL: url) { fraction in
                    Task { @MainActor in
                        if case .analyzing = phase { phase = .analyzing(fraction) }
                    }
                }
                fillers = result.fillers
                audioDuration = result.audioDuration
                phase = .results
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func timecode(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = seconds - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }
}

#Preview {
    ContentView()
}
