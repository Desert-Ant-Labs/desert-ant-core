// Who's case for the browser inference harness (js/test/browser/run.mjs).
//
// `run` executes inside headless Chromium against the real browser entry: the
// Swift -> WebAssembly core plus LiteRT.js on who.tflite (one compile, every
// graph run as a named signature), downloaded from the Hub at the pinned
// revision exactly as a consumer's first page load does. It diarizes the same
// synthetic recording the Node suite does, as samples and as a WAV Blob, and
// times each step. `check` runs in Node on what `run` returns.
import { audio, wav } from "./synthetic.js";

async function rejects(promise) {
  try {
    await promise;
    return "resolved";
  } catch (e) {
    return e?.name ?? String(e);
  }
}

async function timed(fn) {
  const t = performance.now();
  const value = await fn();
  return { value, ms: Math.round(performance.now() - t) };
}

export async function run({ Who }, { litert, litertWasmDir }) {
  const samples = audio(100);
  const load = await timed(() => Who.load({ litert, litertWasmDir }));
  const who = load.value;
  const out = { loadMs: load.ms, timings: {} };
  try {
    const first = await timed(() => who.diarize(samples));
    out.result = first.value.toJSON();
    out.timings.first = first.ms;
    const again = await timed(() => who.diarize(samples));
    out.again = again.value.toJSON();
    out.timings.again = again.ms;
    const blob = new Blob([wav(samples, 16000)], { type: "audio/wav" });
    const viaBlob = await timed(() => who.diarize(blob));
    out.viaBlob = viaBlob.value.toJSON();
    out.timings.viaBlob = viaBlob.ms;
    out.errors = {
      empty: await rejects(who.diarize(new Float32Array(0))),
      unknown: await rejects(who.diarize({})),
    };
  } finally {
    who.dispose();
  }
  out.afterDispose = await rejects(who.diarize(samples));
  return out;
}

export function check(r) {
  const fail = (m) => { throw new Error(m); };
  const { result, again, viaBlob } = r;
  if (!(Math.abs(result.duration - 100) < 1e-6)) fail(`duration ${result.duration}`);
  if (!(result.speakerCount >= 0 && result.speakerCount <= 64)) fail(`speakerCount ${result.speakerCount}`);
  for (const t of result.turns) {
    if (!(t.end > t.start && t.start >= 0 && t.end <= 100.1)) fail(`turn ${t.start}-${t.end}`);
  }
  const starts = result.turns.map((t) => t.start);
  if (starts.some((s, i) => i > 0 && s < starts[i - 1])) fail("turns are not sorted by start");
  if (new Set(result.turns.map((t) => t.speaker)).size !== result.speakerCount) fail("speaker numbering has gaps");
  if (JSON.stringify(again) !== JSON.stringify(result)) fail("the same audio diarized differently the second time");
  if (!(Math.abs(viaBlob.duration - 100) < 1e-3)) fail(`WAV Blob duration ${viaBlob.duration}`);
  if (viaBlob.speakerCount !== result.speakerCount) fail(`WAV Blob found ${viaBlob.speakerCount} speakers, samples ${result.speakerCount}`);
  for (const [name, got] of Object.entries(r.errors)) {
    if (got !== "TypeError") fail(`${name}: expected TypeError, got ${got}`);
  }
  if (r.afterDispose === "resolved") fail("diarize after dispose() resolved");
}
