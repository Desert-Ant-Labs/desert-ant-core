// The clear-node test suite. Runs server-side in Node against the native core
// (the `@desert-ant-labs/clear/native` entry, i.e. node.js). No model is
// committed, so the suite downloads the pinned revision into a directory under
// the package on the first run and reuses it offline afterward. The native core
// picks each OS's runtime and artifact itself: Core ML (.mlmodelc) on macOS,
// LiteRT (.tflite) on Linux. The default universal WebAssembly + LiteRT.js entry
// is exercised by the headless-Chromium example.
import assert from "node:assert/strict";
import { test } from "node:test";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { FfiReader, FfiWriter } from "@desert-ant-labs/core";

import { Clear } from "../node.js";
// From codec.js, not node.js: pure data, so these assert without a native core.
import { LOUDNESS_PRESETS, encodeInput, encodeOptions, decodeResult } from "../codec.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const directory = path.join(here, ".model-cache");

let clear;
let loadError;
try {
  clear = await Clear.load({ directory });
} catch (e) {
  loadError = e;
}
const modelOpts = clear ? {} : { skip: `native model unavailable: ${String(loadError).slice(0, 100)}` };

// A second of noisy tone: enough for several model chunks, cheap to run.
function noisyTone(seconds = 1, sampleRate = 48_000) {
  const n = Math.floor(seconds * sampleRate);
  const out = new Float32Array(n);
  let seed = 12_345;
  for (let i = 0; i < n; i++) {
    seed = (seed * 1_103_515_245 + 12_345) & 0x7fffffff;
    const noise = (seed / 0x7fffffff - 0.5) * 0.1;
    out[i] = 0.3 * Math.sin((2 * Math.PI * 220 * i) / sampleRate) + noise;
  }
  return out;
}

test("the input payload is samples then sample rate", () => {
  const bytes = encodeInput(Float32Array.from([0.5, -0.25]), 48_000);
  const r = new FfiReader(bytes);
  assert.deepEqual(Array.from(r.f32Array()), [0.5, -0.25]);
  assert.equal(r.f64(), 48_000);
  assert.equal(r.remaining, 0);
});

test("a null target bypasses mastering as NaN on the wire", () => {
  const r = new FfiReader(encodeOptions({
    strength: 1, targetLUFS: null, peakCeilingDBFS: -1.5, maxGainDB: 9,
  }));
  assert.equal(r.f64(), 1);
  assert.ok(Number.isNaN(r.f64()));
  assert.equal(r.f64(), -1.5);
  assert.equal(r.f64(), 9);
});

test("NaN measurements decode as null, not NaN", () => {
  const bytes = new FfiWriter()
    .f32Array([0.1, 0.2]).f64(48_000).f64(2).f64(0.5).f64(NaN).f64(NaN).done();
  const result = decodeResult(new FfiReader(bytes));
  assert.equal(result.measuredLUFS, null);
  assert.equal(result.measuredTruePeakDBFS, null);
  assert.equal(result.realtimeFactor, 4);
});

test("a core built before true peak still decodes", () => {
  // The field is appended, so a short payload has to read as absent rather
  // than throw or return garbage.
  const bytes = new FfiWriter()
    .f32Array([0.1]).f64(48_000).f64(1).f64(1).f64(-19).done();
  const result = decodeResult(new FfiReader(bytes));
  assert.equal(result.measuredLUFS, -19);
  assert.equal(result.measuredTruePeakDBFS, null);
});

test("presets carry the published platform targets", () => {
  assert.equal(LOUDNESS_PRESETS.applePodcasts, -19);
  assert.equal(LOUDNESS_PRESETS.spotify, -14);
  assert.equal(LOUDNESS_PRESETS.broadcast, -23);
});

test("enhance returns 48 kHz mono", modelOpts, async () => {
  const r = await clear.enhance(noisyTone(), 48_000);
  assert.equal(r.sampleRate, 48_000);
  assert.ok(r.samples.length > 0);
  assert.ok(r.samples.every(Number.isFinite));
  assert.ok(r.durationSec > 0);
});

test("mastering hits the ceiling and reports both measurements", modelOpts, async () => {
  const r = await clear.enhance(noisyTone(), 48_000, { targetLUFS: "spotify" });
  assert.ok(r.measuredLUFS !== null);
  assert.ok(r.measuredTruePeakDBFS !== null);
  // Limited to the default -1.5 dBTP ceiling, with a little slack for the
  // inter-sample peaks a sample-peak limiter does not see.
  assert.ok(r.measuredTruePeakDBFS <= -1.0,
            `true peak ${r.measuredTruePeakDBFS} above ceiling`);
});

test("bypassing mastering reports no measurements", modelOpts, async () => {
  const r = await clear.enhance(noisyTone(), 48_000, { targetLUFS: null });
  assert.equal(r.measuredLUFS, null);
  assert.equal(r.measuredTruePeakDBFS, null);
});

test("the enhancer is unusable after dispose", modelOpts, async () => {
  const one = await Clear.load({ directory });
  one.dispose();
  await assert.rejects(() => one.enhance(noisyTone(0.1), 48_000));
});
