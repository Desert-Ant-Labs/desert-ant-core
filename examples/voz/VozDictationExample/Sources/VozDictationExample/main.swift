// Voz.Live: dictation, measured the way a user experiences it.
//
//   swift run VozDictationExample --model <dir> --audio speech.wav
//
// The file is pushed through in 10 ms bites with real sleeps between them, so
// the clock sees what a microphone would. Feeding it flat out instead reports a
// latency nobody gets: a streaming workload is idle ~85% of the time by
// construction, the SoC clocks down to match, and the same chunk then takes
// about twice as long as it does on a busy machine.

import AudioIO
import Foundation
import Voz

struct Options {
    var model: String?
    var audio: String?
    var biteMs: Double = 10
    var fast = false
    var refine = true
    var reference: String?
    var interval: Double?
    var context: Double?

    static func parse() -> Options {
        var o = Options()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--model": o.model = it.next()
            case "--audio": o.audio = it.next()
            case "--bite-ms": o.biteMs = Double(it.next() ?? "") ?? 10
            case "--fast": o.fast = true
            case "--no-refine": o.refine = false
            case "--reference": o.reference = it.next()
            case "--interval": o.interval = Double(it.next() ?? "")
            case "--context": o.context = Double(it.next() ?? "")
            default:
                FileHandle.standardError.write(Data("unknown argument \(a)\n".utf8))
                exit(2)
            }
        }
        return o
    }
}

/// Lowercase, strip punctuation, split. Matches the training repo's scorer
/// closely enough to compare runs against each other, which is what this is for.
func normalize(_ text: String) -> [String] {
    text.lowercased()
        .map { $0.isLetter || $0.isNumber || $0 == "'" || $0 == " " ? $0 : " " }
        .reduce(into: "") { $0.append($1) }
        .split(separator: " ").map(String.init)
}

func editDistance(_ a: [String], _ b: [String]) -> Int {
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...max(a.count, 1) where !a.isEmpty {
        current[0] = i
        for j in 1...max(b.count, 1) where !b.isEmpty {
            current[j] = min(previous[j] + 1, current[j - 1] + 1,
                             previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        swap(&previous, &current)
    }
    return previous[b.count]
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = Swift.min(sorted.count - 1,
                          Swift.max(0, Int((p / 100) * Double(sorted.count - 1) + 0.5)))
    return sorted[index]
}

@main
struct Main {
    static func main() async throws {
        let options = Options.parse()
        guard let audioPath = options.audio else {
            print("usage: VozDictationExample --audio speech.wav [--model DIR] "
                  + "[--fast] [--no-refine]")
            exit(2)
        }

        // Loading is the expensive part and it happens once. A dictation app
        // does this at launch, not on the hotkey.
        let loadStart = Date()
        var settings = Voz.Live.Options()
        settings.refine = options.refine
        if let v = options.interval { settings.refineInterval = v }
        if let v = options.context { settings.refineContext = v }
        let live: Voz.Live
        if let model = options.model {
            live = try Voz.Live(modelDirectory: URL(fileURLWithPath: model),
                                options: settings)
        } else {
            live = try await Voz.Live(options: settings)
        }
        let loadSeconds = Date().timeIntervalSince(loadStart)

        // Off the critical path on purpose: the first prediction pays for Core
        // ML's program specialization and for the engine being cold, and a user
        // pressing a hotkey should not.
        let warmSeconds = await live.prewarm()
        let algorithmic = await live.algorithmicLatency
        let chunk = await live.chunkDuration
        print(String(format: "load %.2f s   prewarm %.2f s   chunk %.0f ms   "
                             + "algorithmic latency %.0f ms",
                     loadSeconds, warmSeconds, chunk * 1000, algorithmic * 1000))

        let samples = try await AudioIO.decode(path: audioPath, sampleRate: live.sampleRate)
        guard !samples.isEmpty else { print("no audio"); exit(1) }
        print(String(format: "audio %.1f s, pushed in %.0f ms bites%@\n",
                     Double(samples.count) / live.sampleRate, options.biteMs,
                     options.fast ? " (as fast as possible)" : " at 1x"))

        let stream = await live.start()
        let began0 = Date()
        let collector = Task { () -> ([Double], [Double], Int, Double) in
            var streamingLatency: [Double] = []
            var refinedLatency: [Double] = []
            var revisions = 0
            var firstText = Double.nan
            var shown = ""
            for await update in stream {
                switch update.source {
                case .streaming: streamingLatency.append(update.latency)
                case .refined: refinedLatency.append(update.latency)
                }
                // A dictation client assigns the whole transcript. Here it is
                // rendered as a diff so a revision is visible as a revision:
                // anything that changed behind the insertion point is text the
                // second pass corrected.
                if firstText.isNaN && !update.text.isEmpty {
                    firstText = Date().timeIntervalSince(began0)
                }
                if update.text != shown {
                    if !shown.hasPrefix(update.stable) || !update.text.hasPrefix(shown) {
                        revisions += 1
                    }
                    shown = update.text
                }
            }
            return (streamingLatency, refinedLatency, revisions, firstText)
        }

        let bite = Swift.max(1, Int(options.biteMs * live.sampleRate / 1000))
        let began = Date()
        var index = 0
        while index < samples.count {
            let end = Swift.min(index + bite, samples.count)
            if !options.fast {
                let due = Double(index) / live.sampleRate
                let ahead = due - Date().timeIntervalSince(began)
                if ahead > 0 { try await Task.sleep(nanoseconds: UInt64(ahead * 1e9)) }
            }
            live.append(Array(samples[index..<end]))
            index = end
        }

        let result = try await live.finish()
        let (streamingLatency, refinedLatency, revisions, firstText) = await collector.value

        print(result.text)
        print("")
        print(String(format: "words %d   audio %.1f s   compute %.2f s",
                     result.words.count, result.duration, result.processingTime))
        if !firstText.isNaN {
            // What a dictation user judges the whole thing by: how long after
            // they start talking does anything appear.
            print(String(format: "time to first text  %.0f ms", firstText * 1000))
        }
        if !streamingLatency.isEmpty {
            print(String(format: "streaming latency  p50 %.0f ms   p90 %.0f ms   p99 %.0f ms",
                         percentile(streamingLatency, 50) * 1000,
                         percentile(streamingLatency, 90) * 1000,
                         percentile(streamingLatency, 99) * 1000))
        }
        if !refinedLatency.isEmpty {
            print(String(format: "refined latency    p50 %.0f ms   p90 %.0f ms   "
                                 + "(%d passes, %d revisions)",
                         percentile(refinedLatency, 50) * 1000,
                         percentile(refinedLatency, 90) * 1000,
                         refinedLatency.count, revisions))
        }
        if let path = options.reference,
           let want = try? String(contentsOfFile: path, encoding: .utf8) {
            let r = normalize(want), h = normalize(result.text)
            let edits = editDistance(r, h)
            print(String(format: "WER %.2f%%  (%d edits over %d words)",
                         100 * Double(edits) / Double(max(r.count, 1)), edits, r.count))
        }
        // Duty cycle is the battery number: the Neural Engine's idle rail is
        // hard-gated off, so energy per second of audio tracks it almost
        // exactly.
        if result.duration > 0 {
            let duty = 100 * result.processingTime / result.duration
            print(String(format: "duty %.1f%% of realtime (headroom %.1fx)",
                         duty, 100 / Swift.max(duty, 0.001)))
        }
    }
}
