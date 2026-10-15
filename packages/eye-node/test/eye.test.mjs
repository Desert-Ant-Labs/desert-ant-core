// The eye-node test suite. Runs server-side in Node against the native core (the
// `@desert-ant-labs/eye/native` entry, i.e. node.js). The default browser entry
// is exercised by browser-case.js in headless Chromium.
//
// The expected analysis is the reference the Swift suite checks
// (Tests/EyeTests/Resources/eye_golden.json), so the three SDKs are held to the
// same numbers. The model is adopted from test/fixtures/model when present
// (hermetic), else downloaded from the Hub at the pinned revision.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import { Analysis, Eye, Tag } from "../node.js";
import { expectMatchesReference } from "./expect.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const RESOURCES = path.resolve(HERE, "../../../Tests/EyeTests/Resources");
const FIXTURE_DIR = path.join(HERE, "fixtures", "model");
const golden = JSON.parse(fs.readFileSync(path.join(RESOURCES, "eye_golden.json"), "utf8"));

/** The public-domain beach photo, stored as raw gray bytes. */
function fixture() {
  const gray = fs.readFileSync(path.join(RESOURCES, "eye_fixture.gray"));
  const { width, height } = golden.fixture;
  const data = new Uint8Array(width * height * 3);
  gray.forEach((v, i) => data.set([v, v, v], i * 3));
  return { data, width, height };
}

let eye;
let loadError;
try {
  eye = await Eye.load(fs.existsSync(FIXTURE_DIR) ? { directory: FIXTURE_DIR } : {});
} catch (e) {
  loadError = e;
}
const modelOpts = eye ? {} : { skip: `model unavailable: ${String(loadError).slice(0, 160)}` };

test("the fixture matches the reference analysis", modelOpts, async () => {
  expectMatchesReference(await eye.analyze(fixture()), golden.fixture.analysis);
});

test("parts limit the work", modelOpts, async () => {
  const r = await eye.analyze(fixture(), { parts: ["sharpness"] });
  assert.equal(r.details.photo, null);
  assert.equal(r.details.layout, null);
  assert.equal(r.faces, null);
  assert.equal(r.kind, null);
  assert.equal(r.confidence(Tag.dog), null);
  assert.equal(r.confidence(Tag.blurry), null, "blurry needs the photo and faces parts too");
  assert.ok(r.details.sharpness.score >= 0 && r.details.sharpness.score <= 1);
});

test("every tag the model computes has a constant", modelOpts, async () => {
  const r = await eye.analyze(fixture());
  const computed = new Set([...Object.keys(r.confidences), ...r.faces.flatMap((f) => Object.keys(f.confidences))]);
  assert.deepEqual([...computed].sort(), [...new Set(Object.values(Tag))].sort());
});

test("an analysis round-trips through JSON", modelOpts, async () => {
  const a = await eye.analyze(fixture());
  const b = Analysis.fromJSON(JSON.stringify(a));
  assert.deepEqual(b.confidences, a.confidences);
  assert.deepEqual(b.tags(), a.tags());
  assert.equal(b.kind, a.kind);
  assert.equal(b.details, null);
  assert.deepEqual(Array.from(b.embedding), Array.from(a.embedding));
  assert.equal(b.faces.length, a.faces.length);
  assert.equal(b.faces[0].has(Tag.smiling), a.faces[0].has(Tag.smiling));
  assert.ok(a.similarity(b) > 0.999, "unit length to float16 precision");
  assert.deepEqual(Eye.duplicates([a, b]), [[0, 1]]);
  assert.equal(Eye.best([a, b]), 0);
  assert.deepEqual(a.bestCrop(1) !== null, true);
});

test("RGBA input analyzes like RGB", modelOpts, async () => {
  const { data, width, height } = fixture();
  const rgba = new Uint8ClampedArray(width * height * 4);
  for (let i = 0; i < width * height; i++) rgba.set([data[i * 3], data[i * 3 + 1], data[i * 3 + 2], 255], i * 4);
  const a = await eye.analyze({ data, width, height }, { parts: ["photo"] });
  const b = await eye.analyze({ data: rgba, width, height }, { parts: ["photo"] });
  assert.deepEqual(a, b);
});

test("rejects malformed input", modelOpts, async () => {
  await assert.rejects(eye.analyze({ data: new Uint8Array(5), width: 2, height: 2 }), TypeError);
  await assert.rejects(eye.analyze(fixture(), { parts: ["nope"] }), TypeError);
  await assert.rejects(eye.analyze(fixture(), { maxFaces: -1 }), TypeError);
});

test.after(() => eye?.dispose());
