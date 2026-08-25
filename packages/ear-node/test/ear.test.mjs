// The ear-node test suite. Runs server-side in Node against the native core
// (the `@desert-ant-labs/ear/native` entry, i.e. node.js). No model is
// committed, so the suite downloads the pinned revision into a directory under
// the package on the first run and reuses it offline afterward. The native core
// picks each OS's runtime and artifact itself: Core ML (.mlmodelc) on macOS,
// LiteRT (.tflite) on Linux. The default universal WebAssembly + LiteRT.js entry
// is exercised by the headless-Chromium example.
import assert from "node:assert/strict";
import { test } from "node:test";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { Ear } from "../node.js";
// From codec.js, not node.js: pure data, so these assert without a native core.
import { FfiReader, FfiWriter } from "@desert-ant-labs/core";
import { encodeInput, encodeOptions, decodeResult, SAMPLE_RATE } from "../codec.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const directory = path.join(here, ".model-cache");

/** Speech-shaped noise: syllables at 4 Hz. Enough to get a distribution back,
 *  not enough for it to mean anything - accuracy is measured in Swift against
 *  real recordings, and asserting a language here would be asserting noise. */
function speechLike(seconds = 40) {
  const samples = new Float32Array(SAMPLE_RATE * seconds);
  for (let n = 0; n < samples.length; n++) {
    const t = n / SAMPLE_RATE;
    const syllable = 0.5 + 0.5 * Math.sin(2 * Math.PI * 4 * t);
    samples[n] = syllable * 0.3 * (Math.random() * 2 - 1);
  }
  return samples;
}

let ear;
let loadError;
try {
  ear = await Ear.load({ directory });
} catch (error) {
  loadError = error;
}

// The payload schemas are the contract with Sources/Ear/Binding.swift, and they
// hold whether or not a core loaded, so they are asserted unconditionally.
test("input payload carries the samples and the rate", () => {
  const bytes = encodeInput(new Float32Array([0.1, -0.2, 0.3]), 44_100);
  assert.ok(bytes instanceof Uint8Array);
  assert.ok(bytes.length > 12);
});

test("empty options mean the SDK default", () => {
  assert.equal(encodeOptions().length, 0);
  assert.equal(encodeOptions({}).length, 0);
  assert.ok(encodeOptions({ windows: 5 }).length > 0);
});

test("result decodes the payload Swift writes", () => {
  // Written by hand in the order Sources/Ear/Binding.swift writes it, so this
  // fails if either side reorders the schema rather than appending to it.
  const bytes = new FfiWriter()
    .u32(2)
    .str("pt").f64(0.91)
    .str("es").f64(0.04)
    .f64(3)
    .f64(1)
    .done();
  const detection = decodeResult(new FfiReader(bytes));
  assert.equal(detection.language, "pt");
  assert.equal(detection.confidence, 0.91);
  assert.equal(detection.candidates.length, 2);
  assert.equal(detection.candidates[1].language, "es");
  assert.equal(detection.windows, 3);
  assert.equal(detection.isReliable, true);
});

test("an unreliable answer still reports its language", () => {
  const bytes = new FfiWriter()
    .u32(1).str("sv").f64(0.99).f64(3).f64(0)
    .done();
  const detection = decodeResult(new FfiReader(bytes));
  // Unreliable means "do not route work on this", not "hide it".
  assert.equal(detection.language, "sv");
  assert.equal(detection.isReliable, false);
});

test("model loads", { skip: loadError && `no native core: ${loadError.message}` }, () => {
  assert.ok(ear);
  assert.equal(typeof ear.isDownloaded(), "boolean");
});

test("identifies a language", { skip: loadError && "no native core" }, async () => {
  const detection = await ear.identify(speechLike(), SAMPLE_RATE);
  assert.equal(typeof detection.language, "string");
  assert.ok(detection.language.length > 0);
  assert.ok(detection.confidence > 0 && detection.confidence <= 1);
  assert.ok(detection.windows >= 1);
  assert.equal(typeof detection.isReliable, "boolean");

  // Candidates must be ranked: the first is what every caller reads.
  const probabilities = detection.candidates.map((c) => c.probability);
  assert.deepEqual(probabilities, [...probabilities].sort((a, b) => b - a));
  assert.equal(detection.confidence, probabilities[0]);
});

test("resamples rather than refusing", { skip: loadError && "no native core" }, async () => {
  const detection = await ear.identify(speechLike(), 44_100);
  assert.equal(typeof detection.language, "string");
  assert.ok(detection.windows >= 1);
});

test("window count reaches the model", { skip: loadError && "no native core" }, async () => {
  const one = await ear.identify(speechLike(120), SAMPLE_RATE, { windows: 1 });
  const three = await ear.identify(speechLike(120), SAMPLE_RATE, { windows: 3 });
  assert.equal(one.windows, 1);
  assert.ok(three.windows > 1, `expected more than one window, got ${three.windows}`);
});

test("empty audio is an error, not a guess", { skip: loadError && "no native core" }, async () => {
  await assert.rejects(() => ear.identify(new Float32Array(0), SAMPLE_RATE));
});

test.after(() => ear?.dispose());
