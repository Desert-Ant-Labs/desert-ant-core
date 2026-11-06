// Toxic's case for the browser inference harness (js/test/browser/run.mjs).
//
// `run` executes inside headless Chromium against the real browser entry: the
// Swift -> WebAssembly core plus LiteRT.js on toxic.tflite, downloaded from the
// Hub at the pinned revision exactly as a consumer's first page load does. It
// scores the golden texts, exercises the threshold option and the error paths,
// and times a call. `check` runs in Node on what `run` returns.

const RESOURCES = "/Tests/ToxicTests/Resources/";

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

export async function run({ Toxic }, { litert, litertWasmDir }) {
  const golden = await (await fetch(RESOURCES + "toxic_golden.json")).json();
  const load = await timed(() => Toxic.load({ litert, litertWasmDir }));
  const toxic = load.value;
  const out = { loadMs: load.ms, isDownloaded: toxic.isDownloaded(), golden, results: [], timings: {} };
  try {
    for (const text of golden.texts) {
      const t = await timed(() => toxic.analyze(text));
      out.results.push(t.value);
      out.timings[`text_${out.results.length - 1}`] = t.ms;
    }
    out.low = await toxic.analyze("hello", { thresholds: { HATEFUL: 0 } });
    out.errors = {
      badText: await rejects(toxic.analyze(42)),
      badLabel: await rejects(toxic.analyze("x", { thresholds: { NOPE: 0.5 } })),
    };
    out.api = {
      withCallGroup: typeof toxic.withCallGroup,
      flushTelemetry: typeof toxic.flushTelemetry,
    };
    out.grouped = await toxic.withCallGroup(async (group) => (await toxic.analyze("hello", { group })).scores.HATEFUL);
  } finally {
    toxic.dispose();
  }
  out.afterDispose = await rejects(toxic.analyze("hello"));
  return out;
}

export function check(r) {
  const fail = (m) => { throw new Error(m); };
  if (typeof r.isDownloaded !== "boolean") fail("isDownloaded() is not a boolean");
  // Looser than the native suites: LiteRT.js's wasm kernels land further from
  // the float32 reference than the native runtimes do.
  const TOLERANCE = 0.1;
  const golden = r.golden;
  for (const [k, result] of r.results.entries()) {
    const single = golden.input_ids[k].filter((id) => id !== 0).length < golden.input_ids[k].length;
    for (const [h, head] of golden.heads.entries()) {
      const want = golden.reference[k][h], got = result.scores[head];
      if (single ? !(Math.abs(got - want) < TOLERANCE) : !(got >= want - TOLERANCE)) {
        fail(`text ${k} ${head}: got ${got}, want ${want}`);
      }
    }
  }
  if (!r.results[4].isToxic || !r.results[4].flagged.includes("HATEFUL")) fail("the hateful text was not flagged");
  if (r.results[0].isToxic) fail(`the kind text was flagged: ${JSON.stringify(r.results[0])}`);
  if (!r.low.flagged.includes("HATEFUL") || r.low.thresholds.HATEFUL !== 0) fail("the threshold option did not reach the core");
  for (const [name, got] of Object.entries(r.errors)) {
    if (got !== "TypeError") fail(`${name}: expected TypeError, got ${got}`);
  }
  if (r.api.withCallGroup !== "function" || r.api.flushTelemetry !== "function") fail("API surface");
  if (!(r.grouped >= 0 && r.grouped <= 1)) fail(`grouped call returned ${r.grouped}`);
  if (r.afterDispose === "resolved") fail("analyze after dispose() resolved");
}
