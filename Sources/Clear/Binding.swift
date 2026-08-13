// Clear's side of the cross-language binding: construction, plus the two payload
// schemas that are genuinely model-specific (the options a run takes, and what a
// result looks like). The generic handle lifecycle and the exported symbols live
// in NativeBindings and ClearNative, so this file is only the model's adapter.

import DesertAnt

extension Clear: BoundModel {
    // `isDownloaded()` and `download(progress:)` are Clear's own public API and
    // witness the protocol as they stand.

    /// Input payload: `f32Array` (the first channel), then `f64 sampleRate`,
    /// then optionally `u32 extraChannelCount` and that many more `f32Array`s.
    /// A mono host sends the first two fields and nothing else.
    ///
    /// Options payload: `f64 strength` (0...1), then the mastering chain as
    /// `f64 integratedLUFS` (NaN bypasses mastering), `f64 truePeakDBTP`,
    /// `f64 maxLoudnessGainDB`, then optionally `f64 outputSampleRate`,
    /// `f64 monoDownmix` (1 downmixes, 0 preserves the layout; absent means 1,
    /// which is what every release so far did) and `f64 balanceChannelsLUFS`
    /// (NaN for none).
    /// An empty payload means the SDK defaults (full strength, Apple Podcasts).
    /// A host that wants a preset sends that preset's numbers - the presets
    /// themselves are Swift-side, so no id crosses the boundary and adding one
    /// breaks no host.
    ///
    /// Result payload: `f32Array` (the first channel), then `f64 sampleRate`,
    /// `f64 durationSec`, `f64 processingSec`, `f64 measuredLUFS` (NaN when
    /// mastering was disabled), `f64 measuredTruePeakDBFS` (likewise NaN), then
    /// `u32 extraChannelCount` and that many more `f32Array`s.
    ///
    /// Every group is appended, never reordered, so a host built against an
    /// earlier schema keeps reading the prefix it knows - and since such a host
    /// cannot send extra channels, the mono result it reads is the whole one.
    public func run(input: FFIReader, options: FFIReader) async -> [UInt8]? {
        var input = input
        var options = options
        var channels = [input.f32Array()]
        let sampleRate = input.f64()
        guard !channels[0].isEmpty, sampleRate > 0 else { return nil }
        // `u32` is 4 bytes; anything less means the host stopped at mono.
        if input.remaining >= 4 {
            let extra = input.u32()
            for _ in 0..<extra {
                let channel = input.f32Array()
                guard channel.count == channels[0].count else { return nil }
                channels.append(channel)
            }
        }

        var opts = Options.default
        if !options.isEmpty {
            opts.strength = Strength(options.f64())
            let target = options.f64()
            opts.mastering.enabled = !target.isNaN
            if !target.isNaN { opts.mastering.integratedLUFS = target }
            opts.mastering.truePeakDBTP = options.f64()
            opts.mastering.maxLoudnessGainDB = options.f64()
            if options.remaining >= 8 {
                let rate = options.f64()
                if rate > 0 { opts.sampleRate = rate }
            }
            if options.remaining >= 8 {
                opts.channelMode = options.f64() != 0 ? .mono : .preserve
            }
            if options.remaining >= 8 {
                let balance = options.f64()
                opts.mastering.balanceChannelsLUFS = balance.isNaN ? nil : balance
            }
        }
        guard let result = try? await enhance(channels: channels, sampleRate: sampleRate,
                                              options: opts) else {
            return nil
        }
        var w = FFIWriter()
        w.f32Array(result.channels.first ?? [])
        w.f64(result.sampleRate)
        w.f64(result.durationSec)
        w.f64(result.processingSec)
        w.f64(result.measuredLUFS ?? .nan)
        w.f64(result.measuredTruePeakDBFS ?? .nan)
        w.u32(max(0, result.channels.count - 1))
        for channel in result.channels.dropFirst() { w.f32Array(channel) }
        return w.bytes
    }
}

/// How the generic bindings construct Clear.
public enum ClearBinding: ModelBinding {
    public static let id = ClearModel.id

    public static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        Clear(directory: directory, cacheRoot: cacheRoot)
    }
}
