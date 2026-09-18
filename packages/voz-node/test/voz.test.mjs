// The package's own wiring, against a fake core: what a caller may pass, what
// crosses to the core, and what comes back. Real inference is covered by
// test/browser-case.js in headless Chromium (`mise run test:browser voz`),
// because that is the only place the three graphs actually run.
import test from "node:test";
import assert from "node:assert/strict";
import { makeVoz } from "../voz.js";
import { hubBaseUrl, MODEL_ID, SAMPLE_RATE } from "../codec.js";

const INFO = {
  id: "voz",
  sdkVersion: "3.1.0",
  repo: "desert-ant-labs/voz",
  revision: "web",
  files: ["web/encoder.onnx", "web/meta.json"],
};

/** A core that records what it was handed and returns a fixed transcript. */
function fakeCore() {
  const seen = {};
  return {
    seen,
    exports: {
      modelInfo: () => INFO,
      load: async (meta, vocab, embedding, lanes, batch, fused) => {
        Object.assign(seen, { meta, vocab, embedding, lanes, batch, fused });
        return true;
      },
      transcribeStream: async (seconds, totalSamples, pull, onProgress) => {
        // Drain it the way the core does, so the test sees what a real run
        // would: repeated pulls until one comes back empty.
        const chunks = [];
        for (;;) {
          const next = await pull(16000);
          if (!next.length) break;
          chunks.push(next.length);
        }
        onProgress(1);
        Object.assign(seen, { streamed: { seconds, totalSamples, chunks } });
        return {
          text: "streamed words", words: [{ text: "streamed", start: 0.1, end: 0.5 }],
          duration: seconds, processingTime: 1,
        };
      },
      transcribe: async (samples, onProgress) => {
        seen.samples = samples;
        onProgress(0.5);
        return {
          text: "hello there",
          words: [
            { text: "hello", start: 0.08, end: 0.4 },
            { text: "there", start: 0.48, end: 0.8 },
          ],
          duration: 1,
          processingTime: 0.25,
        };
      },
    },
  };
}

/** A platform seam that hands over the fake core and canned bundle bytes. */
function fakePlatform(core, { meta = {}, decode } = {}) {
  const manifest = {
    decode_lanes: 16, encode_batch: 6, fused_frontend: true, ...meta,
  };
  return {
    setupCore: async () => core,
    defaultOrtWasmDir: async () => undefined,
    makeFetchFile: async ({ info, revision }) => {
      core.seen.fetchedFrom = { repo: info.repo, revision };
      return async (url, name) => {
        core.seen.urls = [...(core.seen.urls ?? []), url];
        if (name === "meta.json") return new TextEncoder().encode(JSON.stringify(manifest));
        if (name.endsWith(".json")) return new TextEncoder().encode("[\"a\"]");
        return new Uint8Array(8);
      };
    },
    decodeAudio: decode ?? (async () => new Float32Array(SAMPLE_RATE)),
    pageUrl: () => "https://app.example.com/dashboard",
    bestProvider: async () => { core.seen.probedProvider = true; return "webgpu"; },
    asBlob: async (input) => (typeof Blob !== "undefined" && input instanceof Blob ? input : null),
    defaultRuntime: async () => { core.seen.usedDefaultRuntime = true; return fakeOrt(); },
  };
}

/** An onnxruntime stand-in: the two entry points the host touches. */
function fakeOrt() {
  return {
    env: { wasm: {}, logLevel: "" },
    Tensor: class { constructor(type, data, dims) { Object.assign(this, { type, data, dims }); } },
    InferenceSession: { create: async () => ({ inputNames: [], outputNames: [], run: async () => ({}) }) },
  };
}

test("the catalog id and rate are the ones the core reports", () => {
  assert.equal(MODEL_ID, "voz");
  assert.equal(SAMPLE_RATE, 16000);
  assert.equal(hubBaseUrl(INFO), "https://huggingface.co/desert-ant-labs/voz/resolve/web/web/");
  assert.equal(hubBaseUrl(INFO, "v9.9.9"),
    "https://huggingface.co/desert-ant-labs/voz/resolve/v9.9.9/web/");
});

test("load takes the bundle's geometry from its manifest, not from the package", async () => {
  const core = fakeCore();
  const Voz = makeVoz(fakePlatform(core, { meta: { decode_lanes: 48, encode_batch: 3 } }));
  await Voz.load({ ort: fakeOrt() });
  assert.equal(core.seen.lanes, 48);
  assert.equal(core.seen.batch, 3);
  assert.equal(core.seen.fused, true);
  // Bytes, not parsed objects: the core parses its own sidecars.
  assert.ok(core.seen.meta instanceof Uint8Array);
  assert.ok(core.seen.vocab instanceof Uint8Array);
  // And the Hub coordinates came from modelInfo().
  assert.deepEqual(core.seen.fetchedFrom, { repo: "desert-ant-labs/voz", revision: "web" });
  assert.ok(core.seen.urls.every((u) => u.startsWith(
    "https://huggingface.co/desert-ant-labs/voz/resolve/web/web/")));
});

test("a self-hosted bundle is served from the caller's URL", async () => {
  const core = fakeCore();
  const Voz = makeVoz(fakePlatform(core));
  await Voz.load({ ort: fakeOrt(), modelBaseUrl: "https://cdn.example.com/voz/" });
  assert.ok(core.seen.urls.every((u) => u.startsWith("https://cdn.example.com/voz/")));
  await assert.rejects(
    Voz.load({ ort: fakeOrt(), modelBaseUrl: "https://cdn.example.com/voz" }),
    /must end in "\/"/);
});

test("a modelBaseUrl may be a path on the app's own origin", async () => {
  // What serving the bundle yourself looks like: a path, not an absolute URL.
  // `new URL(name, base)` rejects a relative base, so this used to throw
  // "Invalid base URL" from inside the first fetch.
  const core = fakeCore();
  const Voz = makeVoz(fakePlatform(core));
  await Voz.load({ ort: fakeOrt(), modelBaseUrl: "/models/voz/" });
  assert.ok(core.seen.urls.every((u) => u.startsWith("https://app.example.com/models/voz/")),
    core.seen.urls.join(" "));
});

test("the runtime comes from the platform seam when the caller passes none", async () => {
  // The browser seam imports onnxruntime-web on demand, so `Voz.load()` takes
  // nothing. Under Node the seam throws the install line instead, because a
  // native addon in the module graph cannot be bundled.
  const core = fakeCore();
  const Voz = makeVoz(fakePlatform(core));
  await Voz.load();
  assert.equal(core.seen.usedDefaultRuntime, true);
});

test("a runtime the caller supplies wins over the seam's", async () => {
  const core = fakeCore();
  const Voz = makeVoz(fakePlatform(core));
  await Voz.load({ ort: fakeOrt() });
  assert.equal(core.seen.usedDefaultRuntime, undefined);
});

test("a seam with no runtime of its own surfaces its instruction", async () => {
  const core = fakeCore();
  const platform = fakePlatform(core);
  platform.defaultRuntime = async () => {
    throw new Error("@desert-ant-labs/voz needs a runtime under Node: npm i onnxruntime-node");
  };
  const Voz = makeVoz(platform);
  await assert.rejects(Voz.load(), /npm i onnxruntime-node/);
});

test("words and their times come back, with the realtime factor computed", async () => {
  const core = fakeCore();
  const Voz = makeVoz(fakePlatform(core));
  const voz = await Voz.load({ ort: fakeOrt() });
  const fractions = [];
  const result = await voz.transcribe(new Float32Array(16000), {
    onProgress: (f) => fractions.push(f),
  });
  assert.equal(result.text, "hello there");
  assert.deepEqual(result.words.map((w) => w.text), ["hello", "there"]);
  assert.equal(result.words[0].start, 0.08);
  assert.ok(result.words[1].end > result.words[1].start);
  assert.equal(result.realtimeFactor, 4);
  assert.deepEqual(fractions, [0.5]);
});

test("samples at another rate are resampled to the model's", async () => {
  const core = fakeCore();
  const Voz = makeVoz(fakePlatform(core));
  const voz = await Voz.load({ ort: fakeOrt() });
  await voz.transcribe(new Float32Array(48000), { sampleRate: 48000 });
  assert.equal(core.seen.samples.length, 16000);
  await voz.transcribe({ samples: new Float32Array(8000), sampleRate: 8000 });
  assert.equal(core.seen.samples.length, 16000);
  // 16 kHz already: handed over untouched.
  const exact = new Float32Array(1600);
  await voz.transcribe(exact);
  assert.equal(core.seen.samples, exact);
});

test("encoded audio is decoded through the platform seam", async () => {
  const core = fakeCore();
  let decoded = null;
  const Voz = makeVoz(fakePlatform(core, {
    decode: async (bytes, rate) => {
      decoded = { length: bytes.length, rate };
      return new Float32Array(3200);
    },
  }));
  const voz = await Voz.load({ ort: fakeOrt() });
  await voz.transcribe(new Uint8Array([1, 2, 3, 4]));
  assert.deepEqual(decoded, { length: 4, rate: 16000 });
  assert.equal(core.seen.samples.length, 3200);
});

test("audio it cannot use is refused with the shapes it accepts", async () => {
  const Voz = makeVoz(fakePlatform(fakeCore()));
  const voz = await Voz.load({ ort: fakeOrt() });
  await assert.rejects(voz.transcribe(new Float32Array(0)), /no samples/);
  await assert.rejects(voz.transcribe(new Int16Array(16)), /Float32Array samples/);
  await assert.rejects(voz.transcribe("audio.wav"), /expected Float32Array samples/);
});

/** A 16-bit mono 16 kHz WAV of `seconds`, as a Blob a caller would pass. */
function wavBlob(seconds) {
  const frames = seconds * 16000;
  const out = new Uint8Array(44 + frames * 2);
  const dv = new DataView(out.buffer);
  const tag = (at, s) => { for (let i = 0; i < 4; i++) out[at + i] = s.charCodeAt(i); };
  tag(0, "RIFF"); dv.setUint32(4, out.length - 8, true); tag(8, "WAVE");
  tag(12, "fmt "); dv.setUint32(16, 16, true); dv.setUint16(20, 1, true);
  dv.setUint16(22, 1, true); dv.setUint32(24, 16000, true);
  dv.setUint32(28, 32000, true); dv.setUint16(32, 2, true); dv.setUint16(34, 16, true);
  tag(36, "data"); dv.setUint32(40, frames * 2, true);
  for (let i = 0; i < frames; i++) dv.setInt16(44 + i * 2, (i % 1000) * 30, true);
  return new Blob([out]);
}

test("a file is streamed rather than read whole, however long it is", async () => {
  // The promise this package makes: memory does not grow with the recording.
  // What proves it here is that the core was fed through `pull` at all, and in
  // chunks - a caller handing over a 40-minute file must not see one array.
  const core = fakeCore();
  const Voz = makeVoz(fakePlatform(core));
  const voz = await Voz.load({ ort: fakeOrt() });
  const result = await voz.transcribe(wavBlob(30));
  assert.equal(result.text, "streamed words");
  assert.equal(core.seen.samples, undefined, "the whole-file path should not have run");
  assert.equal(core.seen.streamed.seconds, 30);
  assert.equal(core.seen.streamed.totalSamples, 480000);
  assert.ok(core.seen.streamed.chunks.length >= 30, "audio arrived in chunks");
  assert.ok(Math.max(...core.seen.streamed.chunks) <= 16000, "a chunk was larger than asked for");
});

test("samples a caller already holds skip the streaming path", async () => {
  // Nothing to stream from: they are in memory either way.
  const core = fakeCore();
  const Voz = makeVoz(fakePlatform(core));
  const voz = await Voz.load({ ort: fakeOrt() });
  await voz.transcribe(new Float32Array(16000));
  assert.equal(core.seen.samples.length, 16000);
  assert.equal(core.seen.streamed, undefined);
});

test("the execution provider is probed rather than assumed", async () => {
  const core = fakeCore();
  const Voz = makeVoz(fakePlatform(core));
  await Voz.load({ ort: fakeOrt() });
  assert.equal(core.seen.probedProvider, true);

  // ...and a caller who names one is not second-guessed.
  const explicit = fakeCore();
  const Explicit = makeVoz(fakePlatform(explicit));
  await Explicit.load({ ort: fakeOrt(), ep: "wasm" });
  assert.equal(explicit.seen.probedProvider, undefined);
});
