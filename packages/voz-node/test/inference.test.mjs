// Real inference under Node, on the same WebAssembly core the browser runs.
//
// Gated, like the Swift suites that need a model: the bundle is 395 MB and
// expands to 1.19 GB resident, which is not something `mise run test:node`
// should download on every run. Point it at a bundle and pass a runtime:
//
//     npm i onnxruntime-node
//     VOZ_WEB_BUNDLE_URL=https://huggingface.co/desert-ant-labs/voz/resolve/web/web/ \
//       node --test test/inference.test.mjs
//
// The browser path is covered instead by test/browser-case.js, which
// `mise run test:browser voz` runs in headless Chromium against the Hub.
import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";

const baseUrl = process.env.VOZ_WEB_BUNDLE_URL;
const HERE = path.dirname(fileURLToPath(import.meta.url));

const runtime = await (async () => {
  if (!baseUrl) return null;
  try {
    return await import("onnxruntime-node");
  } catch {
    return null;
  }
})();

test("Node transcribes with word timestamps", {
  skip: !baseUrl ? "set VOZ_WEB_BUNDLE_URL"
    : !runtime ? "npm i onnxruntime-node" : false,
}, async () => {
  const { Voz } = await import("../browser.js");
  const voz = await Voz.load({ ort: runtime, modelBaseUrl: baseUrl, webnn: false });
  // A path, which is the Node shape of "a file": read in pieces rather than
  // held, so an hour-long recording costs a chunk at a time here too.
  const result = await voz.transcribe(path.join(HERE, "fixtures", "speech.wav"));

  // The fixture is six seconds of a LibriVox recording.
  assert.match(result.text.toLowerCase(), /public domain|volunteer|librivox/);
  assert.ok(Math.abs(result.duration - 6) < 0.2, `duration ${result.duration}`);
  assert.ok(result.words.length > 5, `only ${result.words.length} words`);

  // Times are the point: ordered, inside the audio, and not all zero.
  let last = -1;
  for (const word of result.words) {
    assert.ok(word.text.length > 0);
    assert.ok(word.start >= last, `"${word.text}" starts before its predecessor`);
    assert.ok(word.end >= word.start, `"${word.text}" ends before it starts`);
    assert.ok(word.end <= result.duration + 0.5, `"${word.text}" ends past the audio`);
    last = word.start;
  }
  assert.ok(result.words.at(-1).start > 0.5, "the last word has no plausible time");
  assert.ok(result.realtimeFactor > 0);
});
