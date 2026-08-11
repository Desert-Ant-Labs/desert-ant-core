// The post-DSP mastering chain and the delivery presets that configure it.
//
// Ported from the standalone Clear SDK so callers describe *where the audio is
// going* ("Apple Podcasts") instead of hand-tuning LUFS numbers. The presets are
// the published platform specs, so they belong to the model rather than to each
// app that ships it.
//
// What the core's loudness stage implements today is integrated-LUFS
// normalization with a gain cap and a peak ceiling (`AudioDSP.Loudness`); each
// field below documents how it maps, including the one that does not yet.

public extension Clear {
    /// Post-DSP mastering: where the enhanced audio should land, loudness-wise.
    ///
    /// Build one from a ``Clear/LoudnessPreset`` (`.applePodcasts`, `.spotify`,
    /// …), from ``targetLUFS(_:)`` for a non-standard target, or field by field.
    struct Mastering: Sendable, Equatable {
        /// Integrated loudness target in LUFS.
        public var integratedLUFS: Double

        /// True-peak ceiling in dBTP. -1.5 dBTP leaves headroom for lossy codecs.
        ///
        /// The look-ahead limiter rides *sample* peak, so the ceiling it holds
        /// is slightly optimistic about inter-sample peaks - which is what the
        /// default -1.5 dBTP of headroom absorbs. The true peak that resulted is
        /// measured with 4x oversampling and reported as
        /// ``Clear/Result/measuredTruePeakDBFS``, so a caller can assert against
        /// a delivery spec rather than trust the ceiling.
        public var truePeakDBTP: Double

        /// Loudness range target in LU (spoken word is <= 7 LU; EBU R128
        /// broadcast allows 10).
        ///
        /// Carried so a preset round-trips its full published spec, but **not
        /// yet enforced**: the loudness stage normalizes integrated loudness and
        /// ceils peaks, and has no range compressor. Setting it changes nothing
        /// today; it will start being honoured when that stage lands, without a
        /// source change here.
        public var loudnessRangeLU: Double

        /// Set false to return the unmastered model output, whose level tracks
        /// the input. Equivalent to ``bypass``.
        public var enabled: Bool

        /// Upper bound on the loudness gain in dB.
        ///
        /// The chain normally lifts the output to `integratedLUFS` however quiet
        /// the input was. For a -32 LUFS recording that is +13 dB applied to
        /// everything, and any residual model noise comes up with it. Capping
        /// means a very quiet input lands *under* target but stays clean:
        /// output LUFS = `max(integratedLUFS, inputLUFS + maxLoudnessGainDB)`.
        /// Use `.infinity` to always hit the target.
        public var maxLoudnessGainDB: Double

        public init(integratedLUFS: Double = -19.0,
                    truePeakDBTP: Double = -1.5,
                    loudnessRangeLU: Double = 7.0,
                    enabled: Bool = true,
                    maxLoudnessGainDB: Double = 9.0) {
            self.integratedLUFS = integratedLUFS
            self.truePeakDBTP = truePeakDBTP
            self.loudnessRangeLU = loudnessRangeLU
            self.enabled = enabled
            self.maxLoudnessGainDB = maxLoudnessGainDB
        }

        /// A non-standard integrated-loudness target, with the other defaults.
        public static func targetLUFS(_ lufs: Double) -> Mastering {
            Mastering(integratedLUFS: lufs)
        }

        /// Apple Podcasts spec, -19 LUFS. The default.
        public static let applePodcasts = LoudnessPreset.applePodcasts.mastering
        /// Alias for ``applePodcasts``, for callers that think in content type.
        public static let podcast = LoudnessPreset.applePodcasts.mastering
        /// Spotify's normalization target, -14 LUFS.
        public static let spotify = LoudnessPreset.spotify.mastering
        /// YouTube's normalization target, -14 LUFS.
        public static let youtube = LoudnessPreset.youtube.mastering
        /// EBU R128 broadcast spec, -23 LUFS with a 10 LU range.
        public static let broadcast = LoudnessPreset.broadcast.mastering
        /// Skip mastering: the output level tracks the input.
        public static let bypass = Mastering(enabled: false)
    }

    /// Standard delivery loudness targets. `CaseIterable` so a UI can render a
    /// picker without hardcoding values, and `Identifiable`/`RawRepresentable`
    /// so a selection persists as its `rawValue`.
    ///
    /// Each case yields a fully configured ``Clear/Mastering`` through
    /// ``mastering``; for anything off-spec use ``Clear/Mastering/targetLUFS(_:)``.
    enum LoudnessPreset: String, Sendable, CaseIterable, Identifiable {
        case applePodcasts
        case spotify
        case youtube
        case broadcast

        public var id: String { rawValue }

        /// The integrated-LUFS target this preset normalizes to.
        public var integratedLUFS: Double {
            switch self {
            case .applePodcasts: -19.0
            case .spotify: -14.0
            case .youtube: -14.0
            case .broadcast: -23.0
            }
        }

        /// Human-readable label for a menu row.
        public var displayName: String {
            switch self {
            case .applePodcasts: "Apple Podcasts"
            case .spotify: "Spotify"
            case .youtube: "YouTube"
            case .broadcast: "Broadcast (EBU R128)"
            }
        }

        /// Compact label for a segmented picker, so all four fit on an iPhone.
        public var shortName: String {
            switch self {
            case .applePodcasts: "Apple"
            case .spotify: "Spotify"
            case .youtube: "YouTube"
            case .broadcast: "EBU"
            }
        }

        /// The fully configured mastering chain for this preset. Broadcast
        /// carries R128's wider 10 LU range; the rest take the defaults.
        public var mastering: Mastering {
            switch self {
            case .broadcast: Mastering(integratedLUFS: integratedLUFS, loudnessRangeLU: 10.0)
            default: Mastering(integratedLUFS: integratedLUFS)
            }
        }
    }
}
