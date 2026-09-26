// Schemer's case for the browser inference harness (js/test/browser/run.mjs).
//
// `run` executes inside headless Chromium against the real browser entry: the
// Swift -> WebAssembly core plus LiteRT.js on the three .tflite graphs. It
// loads the model both ways a page can:
//
// * the default: download from the Hub at the pinned revision, verified and
//   kept by the wasm core's own model store;
// * `modelBaseUrl`: files the page serves itself, where the page compiles the
//   encoder and the core compiles the other two graphs beside it.
//
// Until the pinned revision is published, test/fixtures/model (a directory laid
// out like the Hub revision, gitignored) stands in for the Hub: the page's
// `fetch` answers the Hub's tree and resolve URLs from it, with the sizes and
// SHA-256s the core verifies. Without the fixture the default load goes to the
// real Hub. `check` runs in Node on what `run` returns.

const RESOURCES = "/Tests/SchemerTests/Resources/";
const REVISION = "v1.1.0";
const REPO = "desert-ant-labs/schemer";
// The web platform's files (SchemerModel.files[.web]).
const FILES = ["schemer-encoder.tflite", "schemer-decode.tflite", "schemer-label.tflite",
  "schemer_tokenizer.bin", "embeddings.q"];
// Single-threaded wasm is the slowest backend we ship (about 1.3 s a 256 pass
// and 9 s a 1216 pass on an M1), so the browser runs a subset: see `run`. It runs the LiteRT graphs,
// so its answers are the golden's `litert` column.
const LONG = "en-long-document";
const NESTED = ["en-nested-itinerary", "de-nested-shopping"];

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

async function sha256(bytes) {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Answer the Hub's API from a local directory, the way the Hub would: the tree
 * listing with each file's size and LFS SHA-256, then the file bytes. Only
 * this repo and revision are served; everything else goes to the network.
 */
async function serveHubFrom(base) {
  const tree = [];
  for (const path of FILES) {
    const bytes = await (await fetch(base + path)).arrayBuffer();
    tree.push({ type: "file", path, size: bytes.byteLength, lfs: { oid: await sha256(bytes) } });
  }
  const real = globalThis.fetch;
  const seen = [];
  globalThis.fetch = async (input, init) => {
    const url = String(input?.url ?? input);
    if (url.startsWith(`https://huggingface.co/api/models/${REPO}/tree/${REVISION}`)) {
      seen.push("tree");
      return new Response(JSON.stringify(tree), { headers: { "content-type": "application/json" } });
    }
    const prefix = `https://huggingface.co/${REPO}/resolve/${REVISION}/`;
    if (url.startsWith(prefix)) {
      seen.push(url.slice(prefix.length));
      return real(base + url.slice(prefix.length), init);
    }
    return real(input, init);
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

function same(got, want) {
  if (typeof got === "number" && typeof want === "number") return Math.abs(got - want) < 1e-6;
  if ((got === "" || got === null) && (want === "" || want === null)) return true;
  return JSON.stringify(got) === JSON.stringify(want);
}

export async function run({ Schemer, MAX_LABEL_VALUES }, { litert, litertWasmDir, caseDir }) {
  const golden = await (await fetch(RESOURCES + "schemer_golden.json")).json();
  const fixture = `${caseDir}/fixtures/model/`;
  const local = (await fetch(fixture + "schemer_tokenizer.bin", { method: "HEAD" })).ok;
  const out = { local, cases: [], timings: {} };

  // 1. The default path: download (from the stand-in Hub when there is a
  //    fixture), verify, load.
  const hub = local ? await serveHubFrom(fixture) : null;
  let progress = [];
  let load;
  try {
    load = await timed(() => Schemer.load({
      litert, litertWasmDir, onProgress: (f) => progress.push(f),
    }));
  } finally {
    hub?.restore();
  }
  out.hubRequests = hub?.seen ?? [];
  out.progress = { count: progress.length, last: progress.at(-1), monotonic:
    progress.every((v, i) => i === 0 || v >= progress[i - 1]) };
  out.timings.load = load.ms;
  const schemer = load.value;
  try {
    // A third of the flat cases, the long document, and two lists of objects:
    // the harness gives a model five minutes, the download and verification of
    // 232 MB is part of them, and a list of objects runs one pass per property
    // per candidate item (twelve to thirty of them here).
    for (const [i, c] of golden.cases.entries()) {
      const run = c.id === LONG || NESTED.includes(c.id)
        || (!c.id.includes("-nested-") && i % 3 === 0 && c.text.length <= 400);
      if (!run) continue;
      const t = await timed(() => schemer.extract(c.text, c.schema, { now: c.now }));
      out.timings[c.id] = t.ms;
      out.cases.push({ id: c.id, got: t.value, want: c.expected.litert, order: c.schema.map((f) => f.name) });
    }
    out.maxLabelValues = MAX_LABEL_VALUES;
    out.errors = {
      emptyLabel: await rejects(schemer.extract("x", { a: { type: "label", values: [] } })),
      unknownType: await rejects(schemer.extract("x", { a: "nope" })),
    };
    out.api = {
      withCallGroup: typeof schemer.withCallGroup,
      flushTelemetry: typeof schemer.flushTelemetry,
    };
    const first = golden.cases[0];
    out.grouped = await schemer.withCallGroup(async (group) =>
      schemer.extract(first.text, first.schema, { now: first.now, group }));
    out.groupedWant = first.expected.litert;
  } finally {
    schemer.dispose();
  }
  out.afterDispose = await rejects(schemer.extract("x", { a: "string" }));

  // 2. modelBaseUrl: the page serves the files and compiles the encoder.
  if (local) {
    const selfHosted = await timed(() => Schemer.load({ litert, litertWasmDir, modelBaseUrl: fixture }));
    out.timings.selfHostedLoad = selfHosted.ms;
    try {
      out.selfHosted = [];
      for (const c of golden.cases.filter((x) => x.text.length < 200).slice(0, 4)) {
        out.selfHosted.push({ id: c.id, got: await selfHosted.value.extract(c.text, c.schema, { now: c.now }),
          want: c.expected.litert });
      }
    } finally {
      selfHosted.value.dispose();
    }
  }
  return out;
}

// LiteRT.js's WebAssembly kernels are not the native ones, and with
// dynamic-range int8 the activations are quantized per call, so a field that
// sits on a decision boundary can land the other way: measured, 3 of 100
// fields over every golden case. The native suites (Node, Android, Swift) hold
// every field to the golden exactly; the browser is held to all but this
// share, and every disagreement is printed.
const BROWSER_SLACK = 0.05;

export function check(r) {
  const fail = (m) => { throw new Error(m); };
  let fields = 0;
  const disagreements = [];
  const agree = (got, want, what) => {
    for (const [k, v] of Object.entries(want)) {
      fields += 1;
      if (!same(got[k], v)) {
        disagreements.push(`${what}.${k}: got ${JSON.stringify(got[k])}, reference ${JSON.stringify(v)}`);
      }
    }
  };

  if (r.local) {
    // The stand-in Hub was asked for the tree once and every web file once:
    // the core's own store did the download and the verification.
    const files = r.hubRequests.filter((x) => x !== "tree").sort();
    if (r.hubRequests.filter((x) => x === "tree").length !== 1) fail(`tree requests: ${r.hubRequests}`);
    if (JSON.stringify(files) !== JSON.stringify([...FILES].sort())) fail(`downloaded ${files}`);
  }
  if (r.progress.last !== 1 || !r.progress.monotonic) fail(`progress: ${JSON.stringify(r.progress)}`);

  if (r.cases.length < 10) fail(`only ${r.cases.length} cases ran`);
  if (!r.cases.some((c) => c.id === LONG)) fail("the long document (1216 window) did not run");
  for (const id of NESTED) {
    if (!r.cases.some((c) => c.id === id)) fail(`the list of objects ${id} did not run`);
  }
  for (const c of r.cases) {
    if (JSON.stringify(Object.keys(c.got)) !== JSON.stringify(c.order)) fail(`${c.id}: schema order`);
    agree(c.got, c.want, c.id);
  }
  if (r.maxLabelValues !== 16) fail(`MAX_LABEL_VALUES is ${r.maxLabelValues}`);
  for (const [name, got] of Object.entries(r.errors)) {
    if (got !== "TypeError") fail(`${name}: expected TypeError, got ${got}`);
  }
  if (r.api.withCallGroup !== "function" || r.api.flushTelemetry !== "function") fail("API surface");
  agree(r.grouped, r.groupedWant, "grouped");
  if (r.afterDispose === "resolved") fail("extract after dispose() resolved");
  if (r.local) {
    if (!r.selfHosted?.length) fail("the modelBaseUrl path did not run");
    for (const c of r.selfHosted) agree(c.got, c.want, `modelBaseUrl ${c.id}`);
  }
  for (const d of disagreements) console.log(`  schemer (browser) differs from the LiteRT reference: ${d}`);
  if (disagreements.length > Math.ceil(fields * BROWSER_SLACK)) {
    fail(`${disagreements.length} of ${fields} fields differ from the LiteRT reference:\n  `
      + disagreements.join("\n  "));
  }
}
