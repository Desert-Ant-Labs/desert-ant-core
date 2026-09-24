import assert from "node:assert/strict";
import { test } from "node:test";
import path from "node:path";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { FfiReader, FfiWriter } from "@desert-ant-labs/core";
import { createNativeSdk } from "@desert-ant-labs/core/node";
import { Align } from "../node.js";
import { MODEL_ID, PACKAGE_NAME, LANGUAGES, encodeInput, encodeOptions, decodeResult } from "../codec.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_DIR = path.join(here, "fixtures", "model");

let align, loadError;
try { align = await Align.load({ directory: FIXTURE_DIR }); } catch (e) { loadError = e; }
const modelOpts = align ? {} : { skip: `native model unavailable: ${String(loadError).slice(0, 100)}` };

const words = [{ text: "hola", start: 0.4, end: 0.71, confidence: 0.9 }, { text: "mundo", start: 0.8, end: 1.3 }];

test("codec id is the catalog id", () => assert.equal(MODEL_ID, "align"));

const manifestPath = path.join(here, "..", "..", "..", "manifest.json");
const repoOpts = existsSync(manifestPath) ? {} : { skip: "manifest.json is only present inside the repo" };

test("languages match the manifest and the Swift key rule", repoOpts, () => {
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const entry = (manifest.models ?? manifest).find((m) => m.id === "align");
  assert.deepEqual(Align.languages, entry.languages.codes);
  assert.deepEqual(LANGUAGES, entry.languages.codes);
  assert.equal(Align.isSupported("pt-BR"), true);
  assert.equal(Align.isSupported("EN"), true);
  assert.equal(Align.isSupported("xx"), false);
  assert.match(Align.sdkVersion, /^\d+\.\d+\.\d+$/);
});

test("input payload is samples, rate, count, then text/start/end per word", () => {
  const r = new FfiReader(encodeInput(Float32Array.from([0.5, -0.25]), 16000, words));
  assert.deepEqual(Array.from(r.f32Array()), [0.5, -0.25]);
  assert.equal(r.f64(), 16000);
  assert.equal(r.u32(), 2);
  assert.equal(r.str(), "hola"); assert.equal(r.f64(), 0.4); assert.equal(r.f64(), 0.71);
  assert.equal(r.str(), "mundo"); assert.equal(r.f64(), 0.8); assert.equal(r.f64(), 1.3);
  assert.equal(r.remaining, 0);
});

test("options payload is the language string", () => {
  assert.equal(new FfiReader(encodeOptions({ language: "pt-BR" })).str(), "pt-BR");
});

test("result decode scatters times back and preserves extra keys", () => {
  const w = new FfiWriter().u32(2).f64(0.42).f64(0.70).u32(1).f64(0.8).f64(1.3).u32(0);
  assert.deepEqual(decodeResult(new FfiReader(w.done()), words), [
    { text: "hola", start: 0.42, end: 0.70, confidence: 0.9, refined: true },
    { text: "mundo", start: 0.8, end: 1.3, refined: false },
  ]);
});

function tone(seconds = 3, sampleRate = 16000) {
  const out = new Float32Array(seconds * sampleRate);
  for (let i = 0; i < out.length; i++) out[i] = 0.3 * Math.sin((2 * Math.PI * 200 * i) / sampleRate);
  return out;
}

test("refines a transcript through the native core", modelOpts, async () => {
  const out = await align.refine(tone(), 16000, words, { language: "es" });
  assert.equal(out.length, 2);
  assert.ok(out[0].start < out[0].end);
  assert.equal(typeof out[0].refined, "boolean");
  assert.ok(out.some((w) => w.refined), "no word was refined: the native core ran nothing");
});

// Back-to-back words on shared seams, where the two boundary estimates of one seam can cross.
test("refined words keep the input order on shared seams", modelOpts, async () => {
  const texts = "the cat sat on a mat and then it ran to the door of the old red barn by a tree".split(" ");
  const seamed = texts.map((text, i) => ({ text, start: 0.3 + i * 0.18, end: 0.3 + (i + 1) * 0.18 }));
  const n = Math.ceil((0.3 + texts.length * 0.18 + 1) * 16000);
  const audio = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const t = i / 16000;
    audio[i] = 0.3 * Math.sin(2 * Math.PI * 200 * t) + 0.2 * Math.sin(2 * Math.PI * 350 * t)
      + 0.1 * Math.sin(2 * Math.PI * 61 * t) * Math.sin(2 * Math.PI * 3 * t);
  }
  for (const language of ["en", "es"]) {
    const out = await align.refine(audio, 16000, seamed, { language });
    assert.ok(out.some((w) => w.refined), `nothing was refined in ${language}`);
    for (let i = 0; i + 1 < out.length; i++) {
      assert.ok(out[i].end <= out[i + 1].start, `${language}: words ${i} and ${i + 1} overlap`);
    }
    for (const [i, w] of out.entries()) {
      if (w.refined) assert.ok(w.start < w.end, `${language}: refined word ${i} is empty`);
      else assert.deepEqual([w.start, w.end], [seamed[i].start, seamed[i].end]);
    }
  }
});

test("an unsupported language is a passthrough, not an error", modelOpts, async () => {
  const out = await align.refine(tone(), 16000, words, { language: "xx" });
  assert.deepEqual(out.map((w) => [w.start, w.end]), words.map((w) => [w.start, w.end]));
});

test("deviceId and group are accepted per call", modelOpts, async () => {
  await align.withCallGroup(async (group) => {
    const out = await align.refine(tone(), 16000, words, { language: "es", group, deviceId: "channel-123" });
    assert.equal(out.length, 2);
  });
});

test("unusable after dispose", modelOpts, async () => {
  const one = await Align.load({ directory: FIXTURE_DIR });
  one.dispose();
  await assert.rejects(() => one.refine(tone(), 16000, words, { language: "es" }));
});

// Each of these once reached the native core and killed the process with SIGTRAP.
const trappingTimes = [NaN, Infinity, -Infinity, 1e17, 1e19, 1e100, -1e20, undefined];
// Rejected by policy, not because they trap: these used to return a meaningless result.
const outOfRangeTimes = [-5, 1e8];
const hostileTimes = [...trappingTimes, ...outOfRangeTimes];

test("an invalid word time rejects with a RangeError before the core runs", async () => {
  const model = { run() { throw new Error("the core must not be reached"); } };
  const unloaded = new Align(model);
  for (const t of hostileTimes) {
    await assert.rejects(() => unloaded.refine(tone(1), 16000, [{ text: "a", start: t, end: 0.5 }], { language: "en" }),
                         RangeError, `start ${t}`);
    await assert.rejects(() => unloaded.refine(tone(1), 16000, [{ text: "a", start: 0.1, end: t }], { language: "en" }),
                         RangeError, `end ${t}`);
  }
  for (const rate of [NaN, Infinity, 0, -16000]) {
    await assert.rejects(() => unloaded.refine(tone(1), rate, words, { language: "en" }), RangeError, `rate ${rate}`);
  }
  await assert.rejects(() => unloaded.refine(new Float32Array(0), 16000, words, { language: "xx" }), RangeError);
});

test("times at the bounds and past the audio still reach the core", async () => {
  let calls = 0;
  const model = { run() { calls++; return new FfiReader(new FfiWriter().u32(1).f64(0).f64(1).u32(0).done()); } };
  const accepting = new Align(model);
  for (const [start, end] of [[-1, 0], [100, 1e7], ["0.4", "0.7"]]) {
    await accepting.refine(tone(1), 16000, [{ text: "a", start, end }], { language: "en" });
  }
  assert.equal(calls, 3);
});

// Past the JS check, straight at the native core: the Swift side must refuse the same input as a
// failed call, not trap.
test("the native core fails the call on invalid times instead of trapping", modelOpts, async () => {
  const sdk = createNativeSdk({ here: path.join(here, ".."), packageName: PACKAGE_NAME, modelId: MODEL_ID, coreName: "AlignNode" });
  const raw = await sdk.open({ directory: FIXTURE_DIR });
  try {
    for (const t of hostileTimes) {
      for (const language of ["en", "xx"]) {
        const input = encodeInput(tone(1), 16000, [{ text: "a", start: t, end: 0.5 }]);
        await assert.rejects(() => raw.run(input, encodeOptions({ language })), /failed to run/, `start ${t} ${language}`);
      }
    }
    const tiny = encodeInput(tone(1), 1e-300, words);
    await assert.rejects(() => raw.run(tiny, encodeOptions({ language: "en" })), /failed to run/);
    // Past the audio is accepted but has nothing to search, so the input times come back.
    const out = await align.refine(tone(), 16000, [{ text: "late", start: 100, end: 101 }], { language: "en" });
    assert.deepEqual(out.map((w) => [w.start, w.end, w.refined]), [[100, 101, false]]);
  } finally {
    raw.dispose();
  }
});

test.after(() => align?.dispose());

// The default path downloads from the Hub at the pinned tag and caches it.
const networkOpts = process.env.ALIGN_TEST_NETWORK === "1"
  ? {}
  : { skip: "set ALIGN_TEST_NETWORK=1 to exercise the Hugging Face download path" };

test("downloads from the Hugging Face Hub by default, then loads from the cache", networkOpts, async () => {
  const downloaded = await Align.load();
  try {
    assert.equal(downloaded.isDownloaded(), true);
    const out = await downloaded.refine(tone(), 16000, words, { language: "es" });
    assert.equal(out.length, 2);
  } finally {
    downloaded.dispose();
  }
  const again = await Align.load();
  assert.equal(again.isDownloaded(), true);
  again.dispose();
});
