// The who-node test suite. Runs server-side in Node against the native core (the
// `@desert-ant-labs/who/native` entry, i.e. node.js). The default browser entry
// is exercised by browser-case.js in headless Chromium.
//
// The checks are the Swift smoke suite's (Tests/WhoTests/SmokeTests.swift):
// synthetic speech-shaped audio, the answer's shape. The model is adopted from
// test/fixtures/model when present (hermetic), else downloaded from the Hub at
// the pinned revision.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import { Diarization, Who } from "../node.js";
import { audio, wav } from "./synthetic.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_DIR = path.join(HERE, "fixtures", "model");

let who;
let loadError;
try {
  who = await Who.load(fs.existsSync(FIXTURE_DIR) ? { directory: FIXTURE_DIR } : {});
} catch (e) {
  loadError = e;
}
const modelOpts = who ? {} : { skip: `model unavailable: ${String(loadError).slice(0, 160)}` };

function wellFormed(result, seconds) {
  assert.ok(Math.abs(result.duration - seconds) < 1e-6, `duration ${result.duration}`);
  assert.ok(result.speakerCount >= 0 && result.speakerCount <= 64);
  for (const t of result.turns) assert.ok(t.end > t.start && t.start >= 0 && t.end <= seconds + 0.1, `turn ${t.start}-${t.end}`);
  assert.deepEqual(result.turns.map((t) => t.start), [...result.turns.map((t) => t.start)].sort((a, b) => a - b));
  assert.equal(new Set(result.turns.map((t) => t.speaker)).size, result.speakerCount);
}

test("runs end to end on synthetic audio, the same way twice", modelOpts, async () => {
  const samples = audio(100);
  const first = await who.diarize(samples);
  wellFormed(first, 100);
  const again = await who.diarize(samples);
  assert.deepEqual(again.toJSON(), first.toJSON());
});

test("resamples audio at another rate", modelOpts, async () => {
  const result = await who.diarize(audio(40, 48000), { sampleRate: 48000 });
  assert.ok(Math.abs(result.duration - 40) < 0.01, `duration ${result.duration}`);
  const same = await who.diarize({ samples: audio(40, 48000), sampleRate: 48000 });
  assert.ok(Math.abs(same.duration - 40) < 0.01);
});

test("decodes a WAV file's bytes", modelOpts, async () => {
  const samples = audio(30);
  const fromBytes = await who.diarize(wav(samples, 16000));
  const fromSamples = await who.diarize(samples);
  assert.ok(Math.abs(fromBytes.duration - 30) < 1e-3, `duration ${fromBytes.duration}`);
  assert.equal(fromBytes.speakerCount, fromSamples.speakerCount);
});

test("refuses empty audio and unknown input", modelOpts, async () => {
  await assert.rejects(who.diarize(new Float32Array(0)), TypeError);
  await assert.rejects(who.diarize({}), TypeError);
  await assert.rejects(who.diarize("call.wav"), TypeError);
});

test("a recording longer than the window comes back whole", modelOpts, async () => {
  const seconds = 640;
  const result = await who.diarize(audio(seconds));
  wellFormed(result, seconds);
});

test("keepingSpeakers drops the quiet ones and renumbers", () => {
  const result = Diarization.fromJSON({
    turns: [{ speaker: 0, start: 0, end: 10 }, { speaker: 1, start: 10, end: 10.5 }, { speaker: 2, start: 11, end: 20 }],
    duration: 20,
  });
  assert.equal(result.speakerCount, 3);
  assert.deepEqual(result.speakers({ minimumShare: 0.05 }), [0, 2]);
  const kept = result.keepingSpeakers({ minimumShare: 0.05 });
  assert.equal(kept.speakerCount, 2);
  assert.deepEqual(kept.turns.map((t) => [t.speaker, t.start, t.end]), [[0, 0, 10], [1, 11, 20]]);
  assert.equal(result.keepingSpeakers({ minimumShare: 0 }), result);
  assert.deepEqual(Diarization.fromJSON(JSON.stringify(kept)).toJSON(), kept.toJSON());
});

test("dispose releases the model", modelOpts, async () => {
  const other = await Who.load(fs.existsSync(FIXTURE_DIR) ? { directory: FIXTURE_DIR } : {});
  other.dispose();
  await assert.rejects(other.diarize(audio(5)), /disposed/);
});
