import assert from "node:assert/strict";
import { test } from "node:test";
import path from "node:path";
import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { FfiReader, FfiWriter } from "@desert-ant-labs/core";
import { Align } from "../node.js";
import { MODEL_ID, LANGUAGES, encodeInput, encodeOptions, decodeResult } from "../codec.js";

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
