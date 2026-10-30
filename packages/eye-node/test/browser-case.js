// Eye's case for the browser inference harness (js/test/browser/run.mjs).
//
// `run` executes inside headless Chromium against the real browser entry: the
// Swift -> WebAssembly core plus LiteRT.js on eye.tflite (one compile, every
// function run as a named signature), downloaded from the Hub at the pinned
// revision exactly as a consumer's first page load does. It analyzes the
// reference photo as raw pixels and as an ImageBitmap.
// `check` runs in Node on what `run` returns.
//
// Deliberately lean: on a CPU-only host one analyze is over a minute, so this
// runs the full analysis once, plus one photo-only pass for the ImageBitmap
// input path. It used to also time every part in its own analyze, which
// doubled the case and asserted nothing.
import { Analysis } from "../analysis.js";
import { expectMatchesReference } from "./expect.js";

const RESOURCES = "/Tests/EyeTests/Resources/";

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

// Typed arrays do not survive the trip back to Node: send plain arrays.
function plain(analysis) {
  return JSON.parse(JSON.stringify(analysis, (_, v) => (ArrayBuffer.isView(v) ? Array.from(v) : v)));
}

export async function run({ Eye }, { litert, litertWasmDir }) {
  const golden = await (await fetch(RESOURCES + "eye_golden.json")).json();
  const gray = new Uint8Array(await (await fetch(RESOURCES + "eye_fixture.gray")).arrayBuffer());
  const { width, height } = golden.fixture;
  const pixels = { data: new Uint8Array(width * height * 3), width, height };
  gray.forEach((v, i) => pixels.data.set([v, v, v], i * 3));

  const load = await timed(() => Eye.load({ litert, litertWasmDir }));
  const eye = load.value;
  const out = { loadMs: load.ms, timings: {}, golden: golden.fixture.analysis };
  try {
    const all = await timed(() => eye.analyze(pixels));
    out.analysis = { json: all.value.toJSON(), details: plain(all.value.details) };
    out.timings.all = all.ms;
    const imageData = new ImageData(width, height);
    for (let i = 0; i < width * height; i++) imageData.data.set([gray[i], gray[i], gray[i], 255], i * 4);
    out.viaBitmap = plain((await eye.analyze(await createImageBitmap(imageData), { parts: ["photo"] })).details);
    out.errors = {
      badPixels: await rejects(eye.analyze({ data: new Uint8Array(5), width: 2, height: 2 })),
      badPart: await rejects(eye.analyze(pixels, { parts: ["nope"] })),
    };
  } finally {
    eye.dispose();
  }
  out.afterDispose = await rejects(eye.analyze(pixels));
  return out;
}

export function check(r) {
  const fail = (m) => { throw new Error(m); };
  expectMatchesReference(new Analysis(r.analysis.json, r.analysis.details), r.golden);
  const a = r.analysis.details.photo.aesthetic, b = r.viaBitmap.photo.aesthetic;
  if (!(Math.abs(a - b) < 1e-6)) fail(`ImageBitmap input scored ${b}, raw pixels ${a}`);
  for (const [name, got] of Object.entries(r.errors)) {
    if (got !== "TypeError") fail(`${name}: expected TypeError, got ${got}`);
  }
  if (r.afterDispose === "resolved") fail("analyze after dispose() resolved");
}
