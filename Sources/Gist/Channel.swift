import RealModule

/// One post's topic scores (slug -> probability), from `Gist.scores(of:)`.
public struct PostTopics: Sendable {
    public var topics: [String: Double]
    /// Optional epoch-milliseconds timestamp; enables recency weighting.
    public var timestampMillis: Double?

    public init(topics: [String: Double], timestampMillis: Double? = nil) {
        self.topics = topics
        self.timestampMillis = timestampMillis
    }
}

/// A channel-level topic in the ranked roll-up.
public struct ChannelTopic: Sendable, Identifiable, Equatable {
    public var id: String { slug }
    public let slug: String
    /// Share of the channel's total topical weight, `0...1`.
    public let share: Double
    /// Posts that meaningfully touch this topic.
    public let postCount: Int
}

/// Options for `channelTopics`.
public struct RollupOptions: Sendable {
    public var topN: Int
    public var floor: Double
    public var minPosts: Int
    public var halfLifeDays: Double
    public var touch: Double
    public var nowMillis: Double

    public init(topN: Int = 5, floor: Double = 0.05, minPosts: Int = 3,
                halfLifeDays: Double = 0, touch: Double = 0.15, nowMillis: Double = 0) {
        self.topN = topN; self.floor = floor; self.minPosts = minPosts
        self.halfLifeDays = halfLifeDays; self.touch = touch; self.nowMillis = nowMillis
    }
}

/// Aggregate a channel's per-post topic scores into a ranked list of channel-level
/// topics. Pure and deterministic — no model. Probability-weighted with optional
/// recency decay; a share floor and a minimum post count keep one-off posts from
/// characterizing a channel.
public func channelTopics(_ posts: [PostTopics], options: RollupOptions = .init()) -> [ChannelTopic] {
    guard posts.count >= options.minPosts else { return [] }
    let now = options.nowMillis
    let decay = options.halfLifeDays > 0 ? Double.log(2) / (options.halfLifeDays * 86_400_000) : 0

    var weight: [String: Double] = [:]
    var count: [String: Int] = [:]
    for post in posts {
        var w = 1.0
        if decay > 0, let t = post.timestampMillis { w = Double.exp(-decay * max(0, now - t)) }
        for (slug, prob) in post.topics where prob > 0 {
            weight[slug, default: 0] += prob * w
            if prob >= options.touch { count[slug, default: 0] += 1 }
        }
    }
    let total = weight.values.reduce(0, +)
    guard total > 0 else { return [] }

    var topics: [ChannelTopic] = []
    for (slug, mass) in weight {
        let share = mass / total
        if share >= options.floor {
            topics.append(ChannelTopic(slug: slug, share: share, postCount: count[slug] ?? 0))
        }
    }
    topics.sort { $0.share != $1.share ? $0.share > $1.share : $0.slug < $1.slug }
    return Array(topics.prefix(options.topN))
}
