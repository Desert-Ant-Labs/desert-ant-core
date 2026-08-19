// Channel roll-up: aggregate a channel's per-post topic scores into a ranked
// list of channel-level topics. Pure and deterministic - no model. Mirrors
// `channelTopics` in Sources/Gist/Channel.swift, field for field and default for
// default, so the same posts roll up identically on either SDK.

/**
 * @param {{ topics: Record<string, number>, timestampMillis?: number }[]} posts
 * @param {{ topN?: number, floor?: number, minPosts?: number, halfLifeDays?: number, touch?: number, nowMillis?: number }} [options]
 * @returns {{ slug: string, share: number, postCount: number }[]}
 */
export function channelTopics(posts, options = {}) {
  // `nowMillis` defaults to 0, matching Swift: with no clock supplied, `now - t`
  // is negative and clamps to 0, so decay is off until a caller passes one.
  const {
    topN = 5, floor = 0.05, minPosts = 3,
    halfLifeDays = 0, touch = 0.15, nowMillis = 0,
  } = options;
  if (posts.length < minPosts) return [];

  const weight = new Map();
  const count = new Map();
  const decay = halfLifeDays > 0 ? Math.LN2 / (halfLifeDays * 86_400_000) : 0;

  for (const post of posts) {
    let w = 1;
    const t = post.timestampMillis;
    if (decay > 0 && t !== undefined) w = Math.exp(-decay * Math.max(0, nowMillis - t));
    for (const [slug, prob] of Object.entries(post.topics)) {
      if (!(prob > 0)) continue;
      weight.set(slug, (weight.get(slug) ?? 0) + prob * w);
      if (prob >= touch) count.set(slug, (count.get(slug) ?? 0) + 1);
    }
  }

  const total = [...weight.values()].reduce((a, b) => a + b, 0);
  if (total <= 0) return [];

  return [...weight.entries()]
    .map(([slug, mass]) => ({ slug, share: mass / total, postCount: count.get(slug) ?? 0 }))
    .filter((t) => t.share >= floor)
    .sort((a, b) => (b.share !== a.share ? b.share - a.share : a.slug < b.slug ? -1 : 1))
    .slice(0, topN);
}
