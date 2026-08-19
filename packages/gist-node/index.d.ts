// The model-specific half of this package's types. Everything that is the same
// for every model - how a model is loaded, how a call is billed and attributed -
// comes from @desert-ant-labs/core, so it is documented in one place.
import type { CallOptions, ModelLoadOptions } from "@desert-ant-labs/core";

/** A single predicted topic and its probability. */
export interface Topic {
  /** The taxonomy slug, e.g. `"technology"`. */
  slug: string;
  /** The human-readable name, e.g. `"Technology & Software"`. */
  name: string;
  /** The model's probability, `0..1`. */
  score: number;
}

/** One post's topic scores (slug -> probability), for channel roll-up. */
export interface PostTopics {
  topics: Record<string, number>;
  /** Epoch-milliseconds timestamp; enables recency weighting when
   *  `halfLifeDays` and `nowMillis` are both set. */
  timestampMillis?: number;
}

/** A channel-level topic in the ranked roll-up. */
export interface ChannelTopic {
  slug: string;
  /** Share of the channel's total topical weight, `0..1`. */
  share: number;
  /** Posts that meaningfully touch this topic. */
  postCount: number;
}

export interface RollupOptions {
  /** Maximum topics to return (default 5). */
  topN?: number;
  /** Drop topics below this share (default 0.05). */
  floor?: number;
  /** Return nothing for a channel with fewer posts than this (default 3). */
  minPosts?: number;
  /** Recency half-life. 0 (the default) disables decay. */
  halfLifeDays?: number;
  /** Score at which a post counts toward `postCount` (default 0.15). */
  touch?: number;
  /** The clock decay is measured against, epoch milliseconds. Defaults to 0,
   *  which leaves decay off until you supply one - matching the Swift SDK. */
  nowMillis?: number;
}

export interface ClassifyOptions extends CallOptions {
  /** Maximum number of topics to return (default 3). */
  topK?: number;
  /** Override the model's tuned decision threshold. */
  threshold?: number;
}

/** On-device, multi-label content topic tagging (36 topics, 101 languages). */
export declare class Gist {
  /** Load the model, downloading and caching it on first use. */
  static load(options?: ModelLoadOptions): Promise<Gist>;
  /** The full 36-topic probability distribution for `text` (`{ slug: prob }`). */
  scores(text: string, options?: CallOptions): Promise<Record<string, number>>;
  /** The ranked topics for `text` above the model's tuned threshold. The top
   *  topic is always returned; empty input returns `[]`. */
  classify(text: string, options?: ClassifyOptions): Promise<Topic[]>;
  /** Whether the model is usable with no network. */
  isDownloaded(): boolean;
  /** Bill every call made inside `body` as one usage call. */
  withCallGroup<T>(body: (group: string) => Promise<T>): Promise<T>;
  /** Release the model. */
  dispose(): void;
}

/** Aggregate a channel's per-post topic scores into a ranked list of channel
 *  topics. Pure and deterministic — no model. */
export declare function channelTopics(posts: PostTopics[], options?: RollupOptions): ChannelTopic[];
