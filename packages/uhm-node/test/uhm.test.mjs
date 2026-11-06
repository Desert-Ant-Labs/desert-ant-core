// The uhm-node test suite. Runs server-side in Node against the native core
// (the `@desert-ant-labs/uhm/native` entry, i.e. node.js). No model is
// committed, so the suite downloads the pinned revision into a directory under
// the package on the first run and reuses it offline afterward. The default
// browser entry is exercised by test/browser-case.js in headless Chromium.
import assert from "node:assert/strict";
import { test } from "node:test";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { Uhm } from "../node.js";
import { FfiReader, FfiWriter } from "@desert-ant-labs/core";
import { BIAS, SAMPLE_RATE, decodeResult, encodeInput, encodeOptions } from "../codec.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const directory = path.join(here, ".model-cache");

/** Near-silence: a known duration and no fillers to claim. */
function silence(seconds = 2) {
  return new Float32Array(SAMPLE_RATE * seconds).fill(0.001);
}

let uhm;
let loadError;
try {
  uhm = await Uhm.load({ directory });
} catch (error) {
  loadError = error;
}

test("input payload carries samples, rate, and no word group by default", () => {
  const r = new FfiReader(encodeInput(new Float32Array([0.1, -0.2]), 44_100));
  assert.equal(r.f32Array().length, 2);
  assert.equal(r.f64(), 44_100);
  assert.equal(r.remaining, 0);
});

test("words append after the rate", () => {
  const r = new FfiReader(encodeInput(new Float32Array([0]), 16_000, [{ start: 0.1, end: 0.5, text: "hi" }]));
  r.f32Array(); r.f64();
  assert.equal(r.u32(), 1);
  assert.equal(r.f64(), 0.1);
  assert.equal(r.f64(), 0.5);
  assert.equal(r.str(), "hi");
});

test("empty options mean the SDK defaults", () => {
  assert.equal(encodeOptions().length, 0);
  assert.equal(encodeOptions({}).length, 0);
});

test("a bias preset becomes its threshold", () => {
  const r = new FfiReader(encodeOptions({ bias: "precision" }));
  assert.equal(r.f64(), BIAS.precision);
  assert.ok(Number.isNaN(r.f64()));
  assert.equal(r.u32(), 1);
});

test("an unknown bias is refused", () => {
  assert.throws(() => encodeOptions({ bias: "loose" }));
  assert.throws(() => encodeOptions({ bias: "toString" }));
});

test("result decodes the payload Swift writes", () => {
  // Written by hand in the order Sources/Uhm/Binding.swift writes it, so this
  // fails if either side reorders the schema rather than appending to it.
  const bytes = new FfiWriter()
    .f64(12.5)
    .u32(1).f64(3.1).f64(3.4).f64(0.82).str("um")
    .u32(1).f64(0.1).f64(0.5).str("hi")
    .done();
  const result = decodeResult(new FfiReader(bytes));
  assert.equal(result.audioDuration, 12.5);
  assert.deepEqual(result.fillers, [{ start: 3.1, end: 3.4, confidence: 0.82, type: "um" }]);
  assert.deepEqual(result.words, [{ start: 0.1, end: 0.5, text: "hi" }]);
});

test("an empty type is null and a missing word group is null", () => {
  const bytes = new FfiWriter().f64(1).u32(1).f64(0).f64(0.2).f64(0.7).str("").done();
  const result = decodeResult(new FfiReader(bytes));
  assert.equal(result.fillers[0].type, null);
  assert.equal(result.words, null);
});

test("model loads", { skip: loadError && `no native core: ${loadError.message}` }, () => {
  assert.ok(uhm);
  assert.equal(typeof uhm.isDownloaded(), "boolean");
});

test("silence has a duration and no fillers", { skip: loadError && "no native core" }, async () => {
  const result = await uhm.detect(silence(), SAMPLE_RATE);
  assert.ok(Math.abs(result.audioDuration - 2) < 0.05);
  assert.deepEqual(result.fillers, []);
  assert.equal(result.words, null);
});

test("words come back reconciled", { skip: loadError && "no native core" }, async () => {
  const result = await uhm.detect(silence(), SAMPLE_RATE, {
    words: [{ start: 0.1, end: 0.5, text: "hi" }, { start: 1, end: 1, text: "void" }],
  });
  assert.deepEqual(result.words, [{ start: 0.1, end: 0.5, text: "hi" }]);
});

test("resamples rather than refusing", { skip: loadError && "no native core" }, async () => {
  const result = await uhm.detect(new Float32Array(44_100).fill(0.001), 44_100);
  assert.ok(Math.abs(result.audioDuration - 1) < 0.05);
});

test("empty audio is an error, not a guess", { skip: loadError && "no native core" }, async () => {
  await assert.rejects(() => uhm.detect(new Float32Array(0), SAMPLE_RATE));
});

test.after(() => uhm?.dispose());
