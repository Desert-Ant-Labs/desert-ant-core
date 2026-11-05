import Testing
@testable import PlatformSupport

// The tests share the process-wide Log, so each one that changes it restores
// the defaults, and they run one at a time. Other suites in the process log
// meanwhile (a LiteRT compile, say), so what the handler received is filtered
// to this suite's own source.
@Suite(.serialized)
struct LogTests {
    static let source = "logtests"

    final class Received: @unchecked Sendable {
        var entries: [(LogLevel, String, String)] = []
    }

    private func capture(level: LogLevel, _ body: () -> Void) -> [(LogLevel, String, String)] {
        let received = Received()
        Log.level = level
        Log.handler = { received.entries.append(($0, $1, $2)) }
        defer {
            Log.handler = nil
            Log.level = .warning
        }
        body()
        return received.entries.filter { $0.1.hasPrefix(Self.source) }
    }

    @Test func levelsOrderFromTalkativeToSilent() {
        #expect(LogLevel.debug < .info)
        #expect(LogLevel.info < .warning)
        #expect(LogLevel.warning < .error)
        #expect(LogLevel.error < .off)
    }

    @Test func namesParseInAnyCaseWithAliases() {
        #expect(LogLevel(name: "DEBUG") == .debug)
        #expect(LogLevel(name: "verbose") == .debug)
        #expect(LogLevel(name: "Info") == .info)
        #expect(LogLevel(name: "warn") == .warning)
        #expect(LogLevel(name: "warning") == .warning)
        #expect(LogLevel(name: "error") == .error)
        #expect(LogLevel(name: "off") == .off)
        #expect(LogLevel(name: "silent") == .off)
        #expect(LogLevel(name: "loud") == nil)
        for level in [LogLevel.debug, .info, .warning, .error, .off] {
            #expect(LogLevel(name: level.name) == level)
        }
    }

    @Test func handlerReceivesLevelSourceAndMessage() {
        let entries = capture(level: .debug) {
            Log.warning("GPU accelerator could not be loaded", source: "logtests-litert")
            Log.debug("GET https://example.invalid", source: "logtests-http")
            Log.error("boom", source: Self.source)
        }
        #expect(entries.count == 3)
        #expect(entries[0].0 == .warning && entries[0].1 == "logtests-litert")
        #expect(entries[0].2 == "GPU accelerator could not be loaded")
        #expect(entries[1].0 == .debug && entries[1].1 == "logtests-http")
        #expect(entries[2].0 == .error && entries[2].1 == "logtests" && entries[2].2 == "boom")
    }

    @Test func defaultSourceIsCore() {
        final class Seen: @unchecked Sendable { var source: String? }
        let seen = Seen()
        Log.level = .error
        Log.handler = { _, source, message in if message == "logtests-default-source" { seen.source = source } }
        defer {
            Log.handler = nil
            Log.level = .warning
        }
        Log.error("logtests-default-source")
        #expect(seen.source == "core")
    }

    @Test func levelGatesWhatIsWritten() {
        let entries = capture(level: .warning) {
            Log.debug("d", source: Self.source)
            Log.info("i", source: Self.source)
            Log.warning("w", source: Self.source)
            Log.error("e", source: Self.source)
        }
        #expect(entries.map(\.2) == ["w", "e"])
    }

    @Test func offWritesNothing() {
        let entries = capture(level: .off) {
            Log.error("e", source: Self.source)
        }
        #expect(entries.isEmpty)
        Log.level = .off
        defer { Log.level = .warning }
        #expect(!Log.isEnabled(.error))
    }

    @Test func messageIsNotBuiltBelowTheLevel() {
        final class Built: @unchecked Sendable { var count = 0 }
        let built = Built()
        _ = capture(level: .error) {
            Log.debug({ built.count += 1; return "expensive" }(), source: Self.source)
        }
        #expect(built.count == 0)
    }

    @Test func defaultLevelIsWarning() {
        #expect(Log.level == .warning)
        #expect(Log.isEnabled(.warning))
        #expect(!Log.isEnabled(.info))
    }
}
