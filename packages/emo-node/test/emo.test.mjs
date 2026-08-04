// The emo-node test suite. Runs server-side in Node against the native core (the
// `@desert-ant-labs/emo/native` entry, i.e. node.js). The default universal
// WebAssembly + LiteRT.js entry is exercised by the headless-Chromium example.
//
// The npm package does not bundle the model: `Emo.load()` downloads it from the
// Hugging Face Hub at the pinned revision and caches it. We cover both load
// paths: the default HF download (hits the network, skipped when offline) and an
// explicit `directory` that adopts self-hosted files from an offline fixture
// (test/fixtures/model), so the offline/self-hosted story stays green with no
// network.
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import { Emo } from "../node.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_DIR = path.join(HERE, "fixtures", "model");

// Prefer the offline fixture so the suite is hermetic; fall back to the default
// HF download when the fixture is unavailable. Both exercise the same native
// inference; only the resolve/adopt path differs.
let emo;
let loadError;
try {
  emo = await Emo.load({ directory: FIXTURE_DIR });
} catch (e) {
  loadError = e;
}
const modelOpts = emo ? {} : { skip: `native model unavailable: ${String(loadError).slice(0, 120)}` };

test("suggests emoji for an English phrase", modelOpts, async () => {
  const suggestions = await emo.suggestions("Pay my bills", { limit: 5 });
  assert.ok(suggestions.length > 0, "expected suggestions");
  assert.ok(suggestions.some((s) => ["💰", "💳", "🧾", "🏦", "📄"].includes(s.emoji)),
    `got ${suggestions.map((s) => s.emoji).join(" ")}`);
});

test("suggests emoji for a multilingual phrase", modelOpts, async () => {
  const suggestions = await emo.suggestions("犬の散歩", { limit: 5 });
  assert.ok(suggestions.some((s) => ["🐕", "🐾"].includes(s.emoji)),
    `got ${suggestions.map((s) => s.emoji).join(" ")}`);
});

test("ranks by confidence and honors limit", modelOpts, async () => {
  const suggestions = await emo.suggestions("book a flight to Tokyo", { limit: 3 });
  assert.equal(suggestions.length, 3);
  assert.ok(suggestions[0].confidence >= suggestions[1].confidence);
  assert.ok(suggestions.every((s) => s.confidence >= 0 && s.confidence <= 1));
});

test("empty input returns []", modelOpts, async () => {
  assert.deepEqual(await emo.suggestions("   "), []);
});

test.after(() => emo?.dispose());

// The default path downloads from the Hugging Face Hub at the pinned revision
// and caches it. It needs network on a cold cache, so it is opt-in via
// EMO_TEST_NETWORK=1 to keep the default suite hermetic.
const networkOpts = process.env.EMO_TEST_NETWORK === "1"
  ? {}
  : { skip: "set EMO_TEST_NETWORK=1 to exercise the Hugging Face download path" };

test("downloads from the Hugging Face Hub by default and caches", networkOpts, async () => {
  const downloaded = await Emo.load();
  try {
    const suggestions = await downloaded.suggestions("Pay my bills", { limit: 3 });
    assert.ok(suggestions.length > 0, "expected suggestions from the downloaded model");
  } finally {
    downloaded.dispose();
  }
});
