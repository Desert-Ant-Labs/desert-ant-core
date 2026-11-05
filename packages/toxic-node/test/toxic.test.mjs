// The toxic-node test suite. Runs server-side in Node against the native core
// (the `@desert-ant-labs/toxic/native` entry, i.e. node.js). The default
// browser entry is exercised by browser-case.js in headless Chromium.
//
// Expected scores are the reference goldens the Swift suite checks
// (Tests/ToxicTests/Resources/toxic_golden.json), so the three SDKs are held to
// the same numbers. The model is adopted from test/fixtures/model when present
// (hermetic), else downloaded from the Hub at the pinned revision.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import { Toxic } from "../node.js";
import { LABELS } from "../codec.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const RESOURCES = path.resolve(HERE, "../../../Tests/ToxicTests/Resources");
const FIXTURE_DIR = path.join(HERE, "fixtures", "model");
const golden = JSON.parse(fs.readFileSync(path.join(RESOURCES, "toxic_golden.json"), "utf8"));
/** The published artifact against the torch float32 reference. */
const TOLERANCE = 0.1; // the 4-bit table and the dynamic int8 layers against torch float32: 0.081 at v0.2.2

let toxic;
let loadError;
try {
  toxic = await Toxic.load(fs.existsSync(FIXTURE_DIR) ? { directory: FIXTURE_DIR } : {});
} catch (e) {
  loadError = e;
}
const modelOpts = toxic ? {} : { skip: `model unavailable: ${String(loadError).slice(0, 160)}` };

/** Whether a golden text fits one window: its ids are the window the goldens carry. */
function singleWindow(k) {
  return golden.input_ids[k].filter((id) => id !== 0).length < golden.input_ids[k].length;
}

test("golden texts match the reference", modelOpts, async () => {
  for (const [k, text] of golden.texts.entries()) {
    const result = await toxic.analyze(text);
    for (const [h, head] of golden.heads.entries()) {
      const want = golden.reference[k][h];
      const got = result.scores[head];
      if (singleWindow(k)) {
        assert.ok(Math.abs(got - want) < TOLERANCE, `text ${k} ${head}: got ${got}, want ${want}`);
      } else {
        assert.ok(got >= want - TOLERANCE, `text ${k} ${head}: got ${got}, want at least ${want}`);
      }
    }
  }
});

test("a hateful text is flagged and a kind one is not", modelOpts, async () => {
  const hateful = await toxic.analyze(golden.texts[4]);
  assert.equal(hateful.isToxic, true);
  assert.ok(hateful.flagged.includes("HATEFUL"));
  assert.ok(hateful.content.includes("HATEFUL"));
  const kind = await toxic.analyze(golden.texts[0]);
  assert.equal(kind.isToxic, false);
  assert.deepEqual(kind.content, []);
  assert.deepEqual(Object.keys(kind.scores).sort(), [...LABELS].sort());
});

test("thresholds replace the model's defaults for the heads named", modelOpts, async () => {
  const defaults = await toxic.analyze("hello");
  const low = await toxic.analyze("hello", { thresholds: { HATEFUL: 0 } });
  assert.ok(low.flagged.includes("HATEFUL"));
  assert.equal(low.thresholds.HATEFUL, 0);
  assert.equal(low.thresholds.ABUSIVE, defaults.thresholds.ABUSIVE);
  assert.deepEqual(low.scores, defaults.scores);
});

test("rejects malformed input", modelOpts, async () => {
  await assert.rejects(toxic.analyze(42), TypeError);
  await assert.rejects(toxic.analyze("x", { thresholds: { NOPE: 0.5 } }), TypeError);
  await assert.rejects(toxic.analyze("x", { thresholds: { HATEFUL: "high" } }), TypeError);
});

test.after(() => toxic?.dispose());
