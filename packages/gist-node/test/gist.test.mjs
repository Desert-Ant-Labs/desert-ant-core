// The gist-node test suite. Runs server-side in Node against the native core (the
// `@desert-ant-labs/gist/native` entry, i.e. node.js). The default universal
// WebAssembly + LiteRT.js entry is exercised by the headless-Chromium example.
//
// The npm package does not bundle the model: `Gist.load()` downloads it from the
// Hugging Face Hub at the pinned revision and caches it. The channel roll-up is
// pure JS, so its tests need no model at all and always run.
import assert from "node:assert/strict";
import { test } from "node:test";

import { Gist, channelTopics } from "../node.js";

let gist;
let loadError;
try {
  gist = await Gist.load();
} catch (e) {
  loadError = e;
}
const modelOpts = gist ? {} : { skip: `native model unavailable: ${String(loadError).slice(0, 120)}` };

test("classifies an English phrase", modelOpts, async () => {
  const topics = await gist.classify("A one-pan roast chicken recipe for weeknights");
  assert.ok(topics.length > 0, "expected topics");
  assert.ok(topics.some((t) => t.slug === "food-drink"), `got ${topics.map((t) => t.slug).join(" ")}`);
  for (const t of topics) {
    assert.ok(t.name.length > 0, `${t.slug} has no display name`);
    assert.ok(t.score >= 0 && t.score <= 1, `${t.slug} score out of range`);
  }
});

test("classifies a multilingual phrase", modelOpts, async () => {
  const topics = await gist.classify("El equipo gana la final de la copa");
  assert.ok(topics.some((t) => t.slug === "sports"), `got ${topics.map((t) => t.slug).join(" ")}`);
});

test("scores cover the whole taxonomy", modelOpts, async () => {
  const scores = await gist.scores("How to start a podcast with just your iPhone");
  assert.equal(Object.keys(scores).length, 36, "the taxonomy is 36 topics");
  for (const [slug, p] of Object.entries(scores)) {
    assert.ok(p >= 0 && p <= 1, `${slug} = ${p} is not a probability`);
  }
});

test("classify is ranked and respects topK", modelOpts, async () => {
  const topics = await gist.classify("How to start a podcast with just your iPhone", { topK: 5 });
  assert.ok(topics.length <= 5);
  const scores = topics.map((t) => t.score);
  assert.deepEqual(scores, [...scores].sort((a, b) => b - a), "topics must be ranked");
});

test("classify always returns the top topic below threshold", modelOpts, async () => {
  const topics = await gist.classify("asdfgh qwerty", { threshold: 0.99 });
  assert.equal(topics.length, 1, `got ${topics.map((t) => t.slug).join(" ")}`);
});

test("empty input classifies to nothing", modelOpts, async () => {
  assert.deepEqual(await gist.classify("   "), []);
  assert.deepEqual(await gist.scores(""), {});
});

// --- channel roll-up: pure, no model -----------------------------------------

const post = (topics, timestampMillis) => ({ topics, timestampMillis });

test("channel roll-up ranks by share and counts touching posts", () => {
  const rolled = channelTopics([
    post({ "food-drink": 0.9, travel: 0.2 }),
    post({ "food-drink": 0.8 }),
    post({ "food-drink": 0.7, travel: 0.3 }),
  ]);
  assert.equal(rolled[0].slug, "food-drink");
  assert.equal(rolled[0].postCount, 3);
  assert.ok(rolled[0].share > 0.5);
  const shares = rolled.map((t) => t.share);
  assert.deepEqual(shares, [...shares].sort((a, b) => b - a));
  assert.ok(Math.abs(rolled.reduce((a, t) => a + t.share, 0) - 1) < 1e-9 || rolled.length < 2);
});

test("channel roll-up needs minPosts", () => {
  assert.deepEqual(channelTopics([post({ travel: 0.9 })]), []);
  assert.equal(channelTopics([post({ travel: 0.9 })], { minPosts: 1 }).length, 1);
});

test("channel roll-up drops topics under the floor", () => {
  const rolled = channelTopics(
    [post({ a: 1 }), post({ a: 1 }), post({ a: 1, b: 0.01 })],
    { minPosts: 3, floor: 0.05 });
  assert.deepEqual(rolled.map((t) => t.slug), ["a"]);
});

// The bug this migration fixed: the standalone package read `post.timestamp` and
// `options.now` while its types (and Swift) said `timestampMillis`/`nowMillis`,
// so decay silently never applied to anyone following the types.
test("recency decay uses timestampMillis and nowMillis", () => {
  const now = 10 * 86_400_000;
  const old = post({ a: 1 }, 0);
  const fresh = post({ b: 1 }, now);
  const rolled = channelTopics([old, fresh, post({ b: 1 }, now)],
    { minPosts: 3, halfLifeDays: 1, nowMillis: now, floor: 0 });
  const a = rolled.find((t) => t.slug === "a");
  const b = rolled.find((t) => t.slug === "b");
  assert.ok(b.share > a.share, "the fresher topic must outweigh the decayed one");
  assert.ok(a.share < 0.01, `10 half-lives should leave almost nothing, got ${a.share}`);
});

test("recency decay stays off without a clock, matching Swift", () => {
  const posts = [post({ a: 1 }, 0), post({ b: 1 }, 9e12), post({ b: 1 }, 9e12)];
  const withoutClock = channelTopics(posts, { minPosts: 3, halfLifeDays: 1, floor: 0 });
  const a = withoutClock.find((t) => t.slug === "a");
  assert.ok(Math.abs(a.share - 1 / 3) < 1e-9, `expected undecayed thirds, got ${a.share}`);
});
