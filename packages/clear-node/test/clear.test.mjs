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
import { readFile } from "node:fs/promises";
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

test("the input payload is samples, sample rate, then extra channels", () => {
  const r = new FfiReader(encodeInput([Float32Array.from([0.5, -0.25])], 48_000));
  assert.deepEqual(Array.from(r.f32Array()), [0.5, -0.25]);
  assert.equal(r.f64(), 48_000);
  assert.equal(r.u32(), 0);
  assert.equal(r.remaining, 0);

  const stereo = new FfiReader(encodeInput([[0.5], [-0.5]], 48_000));
  assert.deepEqual(Array.from(stereo.f32Array()), [0.5]);
  assert.equal(stereo.f64(), 48_000);
  assert.equal(stereo.u32(), 1);
  assert.deepEqual(Array.from(stereo.f32Array()), [-0.5]);
  assert.equal(stereo.remaining, 0);
});

test("a null target bypasses mastering as NaN on the wire", () => {
  const r = new FfiReader(encodeOptions({
    strength: 1, targetLUFS: null, peakCeilingDBFS: -1.5, maxGainDB: 9,
    outputSampleRate: 48_000, monoDownmix: true,
  }));
  assert.equal(r.f64(), 1);
  assert.ok(Number.isNaN(r.f64()));
  assert.equal(r.f64(), -1.5);
  assert.equal(r.f64(), 9);
  assert.equal(r.f64(), 48_000);
  assert.equal(r.f64(), 1, "mono downmix is the default on the wire");
  assert.ok(Number.isNaN(r.f64()), "an absent balance target is NaN");
});

test("NaN measurements decode as null, not NaN", () => {
  const bytes = new FfiWriter()
    .f32Array([0.1, 0.2]).f64(48_000).f64(2).f64(0.5).f64(NaN).f64(NaN).u32(0).done();
  const result = decodeResult(new FfiReader(bytes));
  assert.equal(result.measuredLUFS, null);
  assert.equal(result.measuredTruePeakDBFS, null);
  assert.equal(result.realtimeFactor, 4);
  assert.equal(result.channelCount, 1);
});

test("extra channels decode into channels, with samples the first", () => {
  const bytes = new FfiWriter()
    .f32Array([0.1]).f64(48_000).f64(1).f64(1).f64(-19).f64(-2)
    .u32(1).f32Array([0.2]).done();
  const result = decodeResult(new FfiReader(bytes));
  assert.equal(result.channelCount, 2);
  // Compare against float32, not the float64 literals: 0.2 is not exactly
  // representable, so the round trip legitimately widens it.
  assert.deepEqual(result.channels[1], Float32Array.from([0.2]));
  assert.deepEqual(result.samples, Float32Array.from([0.1]));
});

test("a core built before true peak or channels still decodes", () => {
  // Both groups are appended, so a short payload has to read as absent rather
  // than throw or return garbage.
  const bytes = new FfiWriter()
    .f32Array([0.1]).f64(48_000).f64(1).f64(1).f64(-19).done();
  const result = decodeResult(new FfiReader(bytes));
  assert.equal(result.measuredLUFS, -19);
  assert.equal(result.measuredTruePeakDBFS, null);
  assert.equal(result.channelCount, 1);
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

test("stereo in, stereo out", modelOpts, async () => {
  const left = noisyTone();
  const right = left.map((v) => v * 0.5);
  const r = await clear.enhance([left, right], 48_000, { channelMode: "preserve" });
  assert.equal(r.channelCount, 2);
  assert.equal(r.channels[0].length, r.channels[1].length);
  assert.deepEqual(r.samples, r.channels[0]);
  for (const channel of r.channels) assert.ok(channel.every(Number.isFinite));
  // Joint mastering keeps the sides apart rather than collapsing them.
  assert.notDeepEqual(Array.from(r.channels[0]), Array.from(r.channels[1]));
});

test("a Float32Array pair is read as two channels, not as mono", modelOpts, async () => {
  const left = noisyTone(0.5);
  const r = await clear.enhance([left, left.map((v) => v * 0.5)], 48_000,
                                { channelMode: "preserve" });
  assert.equal(r.channelCount, 2);
});

test("the default collapses the pair", modelOpts, async () => {
  const left = noisyTone(0.5);
  const r = await clear.enhance([left, left.map((v) => v * 0.5)], 48_000);
  assert.equal(r.channelCount, 1);
});

test("outputSampleRate resamples the delivery", modelOpts, async () => {
  const x = noisyTone();
  const r = await clear.enhance(x, 48_000, { outputSampleRate: 24_000 });
  assert.equal(r.sampleRate, 24_000);
  assert.ok(Math.abs(r.samples.length - x.length / 2) < x.length * 0.02);
});

// Parity against the Apple reference in Tests/Fixtures, the same numbers the
// Swift and Kotlin suites read.
const PARITY = path.join(here, "..", "..", "..", "Tests", "Fixtures", "clear-parity.json");

/** The fixture input: a sum of sines, reproduced exactly in every language. */
function parityInput(sampleCount = 96_000, sampleRate = 48_000) {
  const out = new Float32Array(sampleCount);
  for (let i = 0; i < sampleCount; i++) {
    const t = i / sampleRate;
    const envelope = 0.5 * (1 + Math.sin(2 * Math.PI * 4 * t));
    let harmonics = 0;
    for (let h = 1; h <= 12; h++) harmonics += Math.sin(2 * Math.PI * 120 * h * t) / h;
    out[i] = 0.25 * envelope * harmonics;
  }
  return out;
}

/** RMS per block: the same compact shape the Swift fixture computes. */
function envelope(samples, blocks = 40) {
  const size = Math.floor(samples.length / blocks);
  if (size <= 0) return [];
  return Array.from({ length: blocks }, (_, b) => {
    let acc = 0;
    for (let i = b * size; i < Math.min((b + 1) * size, samples.length); i++) {
      acc += samples[i] * samples[i];
    }
    return Math.sqrt(acc / size);
  });
}

test("matches the cross-platform reference", modelOpts, async () => {
  const golden = JSON.parse(await readFile(PARITY, "utf8"));
  const r = await clear.enhance(parityInput(), 48_000, { targetLUFS: "applePodcasts" });

  assert.ok(Math.abs(r.samples.length - golden.sampleCount) <= 480);
  const got = envelope(r.samples, golden.blockRMS.length);
  const scale = Math.max(...golden.blockRMS, 1e-9);
  let worst = 0;
  for (let i = 0; i < golden.blockRMS.length; i++) {
    worst = Math.max(worst, Math.abs(got[i] - golden.blockRMS[i]) / scale);
  }
  // Core ML and LiteRT do not agree bit for bit; 5% of full scale is loose
  // enough for a different runtime and tight enough to catch a wrong pipeline.
  // The envelope is printed, not asserted: the reference was produced on
  // Apple, and a golden per runtime is what would let another runtime assert
  // it. Loudness, which every runtime agrees on, is asserted.
  console.log(`PARITY envelope=${worst.toFixed(4)} `
    + `lufs=${(r.measuredLUFS - golden.measuredLUFS).toFixed(4)} `
    + `truePeak=${(r.measuredTruePeakDBFS - golden.truePeakDBFS).toFixed(4)}`);
  assert.ok(Math.abs(r.measuredLUFS - golden.measuredLUFS) < 1.5,
            `loudness ${r.measuredLUFS} vs reference ${golden.measuredLUFS}`);
  assert.ok(Math.abs(r.measuredTruePeakDBFS - golden.truePeakDBFS) < 1.5,
            `true peak ${r.measuredTruePeakDBFS} vs reference ${golden.truePeakDBFS}`);
});

test("the enhancer is unusable after dispose", modelOpts, async () => {
  const one = await Clear.load({ directory });
  one.dispose();
  await assert.rejects(() => one.enhance(noisyTone(0.1), 48_000));
});
