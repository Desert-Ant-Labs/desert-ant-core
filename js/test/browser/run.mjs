#!/usr/bin/env node
// Browser inference: run every model's real browser path in headless Chromium (or DAL_BROWSER_ENGINE).
//
// Why this exists: the browser is the *default* entry of every model package
// (`import { Emo } from "@desert-ant-labs/emo"`). The bundle matrix proves the package *builds* for
// the browser; test:wasi proves the Swift core runs under wasm but with the
// model-backed tests compiled out. Neither loads real weights and runs LiteRT.js
// in a real browser engine, which is exactly what a consumer does.
//
// What it does, per model:
//   1. serves the repo over HTTP (the wasm core, the package sources, and the
//      workspace's node_modules, so the *local* @desert-ant-labs/core is used);
//   2. generates a page whose import map is built from real Node resolution, so
//      it follows npm's hoisting instead of hardcoding a layout;
//   3. imports that model's packages/<model>-node/test/browser-case.js and runs
//      it, which downloads the pinned model from the Hub and does inference;
//   4. asserts the case's own check() back in Node.
//
// Adding a model means adding its browser-case.js; nothing here changes. A
// case that exports `checksLicense` also runs twice more under a simulated
// license outage, asserting the outage changes neither the output nor the
// time. The license client is shared core plumbing, so one cheap case is
// enough: redact carries it for the LiteRT.js path. Running the outage pair
// for every model would triple the heavy cases (eye alone is ~4 minutes a run
// on a CPU-only host) for no extra license coverage; voz's case says why it
// opts out too.
// A case that needs a runtime of its own says so by exporting `imports`, a list
// of specifiers resolved from its own package and added to the page's import
// map: Voz's runtime (onnxruntime-web) is the caller's to supply, so it cannot
// be a fixed part of the page the way LiteRT.js is.
//
// Needs `mise run build:wasm` first (a stub dist cannot infer) and network for
// the model download.
//
// Usage:
//   node test/browser/run.mjs                # every model
//   node test/browser/run.mjs --only emo
//   node test/browser/run.mjs --headed       # watch it
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
/** The case file per model; a model may keep others beside it, e.g. a benchmark. */
const CASE = process.env.DAL_BROWSER_CASE ?? "browser-case.js";
const PORT = Number(process.env.DAL_BROWSER_PORT ?? 8766);
const TIMEOUT_MS = Number(process.env.DAL_BROWSER_TIMEOUT_MS ?? 300_000);

const args = process.argv.slice(2);
const only = (() => {
  const i = args.indexOf("--only");
  return i === -1 ? null : args[i + 1]?.split(",").map((s) => s.trim());
})();

const log = (...m) => console.log(...m);
const die = (m) => {
  console.error(`error: ${m}`);
  process.exit(1);
};

// ---------------------------------------------------------------- discovery

/** Every model package that ships a browser entry and a browser test case. */
function findCases() {
  const dir = path.join(REPO, "packages");
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((d) => d.endsWith("-node"))
    .map((d) => ({ model: d.slice(0, -"-node".length), dir: path.join(dir, d) }))
    .filter((p) => fs.existsSync(path.join(p.dir, "test", CASE)))
    .filter((p) => !only || only.includes(p.model))
    .sort((a, b) => a.model.localeCompare(b.model));
}

/** Load each case in Node, for the `imports` it declares and the `check` it
 *  runs afterwards. Top-level code in a case must therefore be Node-safe,
 *  which is why a case imports a browser runtime inside `run`. */
async function loadCases(entries) {
  return Promise.all(entries.map(async (entry) => ({
    ...entry,
    module: await import(pathToFileURL(path.join(entry.dir, "test", CASE))),
  })));
}

/** An absolute path inside the repo, as a URL the harness server will serve. */
const urlFor = (abs) => "/" + path.relative(REPO, abs).split(path.sep).join("/");

/**
 * The page's import map, resolved the way Node would resolve it from the
 * package itself. That keeps this correct whether npm hoists a dependency to the
 * workspace root or nests it, and it is what makes `@desert-ant-labs/core`
 * resolve to the local js/ through the workspace symlink rather than to a
 * published copy.
 */
function importMap({ model, dir, module }) {
  const require = createRequire(path.join(dir, "package.json"));
  const resolve = (spec) => {
    try {
      return urlFor(require.resolve(spec));
    } catch {
      die(`${model}: cannot resolve ${spec}; run \`mise run build:wasm\` and \`npm install\``);
    }
  };
  // LiteRT.js is every other model's runtime, and Voz's package does not depend
  // on it, so it is included when the package can resolve it rather than
  // always.
  const optional = (spec) => {
    try {
      return urlFor(require.resolve(spec));
    } catch {
      return null;
    }
  };
  // A case's own runtime has to be resolved under the *import* condition, not
  // require's: onnxruntime-web maps "./all" to a CJS bundle for require and an
  // ESM one for import, and a page given the CJS file gets a module with no
  // exports on it. `require.resolve` cannot ask for a condition, so this goes
  // through ESM resolution and falls back for anything it cannot see.
  const resolveModule = (spec) => {
    try {
      return urlFor(fileURLToPath(import.meta.resolve(spec)));
    } catch {
      return resolve(spec);
    }
  };
  const map = {
    // The package under test, and the browser side of its `#platform` condition,
    // which an import map has to spell out (it is package-internal).
    [`@desert-ant-labs/${model}`]: urlFor(path.join(dir, "browser.js")),
    "#platform": urlFor(path.join(dir, "platform-browser.js")),
    "@desert-ant-labs/core": resolve("@desert-ant-labs/core"),
    // Whatever the case asked for.
    ...Object.fromEntries((module?.imports ?? []).map((spec) => [spec, resolveModule(spec)])),
  };
  for (const spec of [
    "@desert-ant-labs/core/audio", "@bjorn3/browser_wasi_shim",
    "@litertjs/core", "@litertjs/wasm-utils",
  ]) {
    const url = optional(spec);
    if (url) map[spec] = url;
  }
  return map;
}

function renderPage(entry) {
  const map = importMap(entry);
  // The runtime's own wasm/ sits beside the package entry LiteRT.js resolves to.
  const litert = map["@litertjs/core"];
  const wasmDir = litert ? path.posix.join(path.posix.dirname(litert), "../wasm/") : "";
  const caseDir = urlFor(path.join(entry.dir, "test"));
  return `<!doctype html>
<html><body>
<script type="importmap">${JSON.stringify({ imports: map })}</script>
<script type="module">
  import { run } from "${caseDir}/${CASE}";

  // Only for the models whose runtime this is; a case that brings its own
  // imports it itself.
  const litert = ${litert ? 'await import("@litertjs/core")' : "null"};
  const mod = await import("@desert-ant-labs/${entry.model}");
  const started = performance.now();
  run(mod, { litert, litertWasmDir: "${wasmDir}", caseDir: "${caseDir}" }).then(
    (result) => { window.__result = { result, ms: Math.round(performance.now() - started) }; },
    (error) => { window.__error = String((error && error.stack) || error); },
  );
</script>
</body></html>`;
}

// ---------------------------------------------------------------- server

const MIME = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".wasm": "application/wasm",
  ".json": "application/json",
  ".bin": "application/octet-stream",
  ".tflite": "application/octet-stream",
};

function serve(pages) {
  return http.createServer(async (req, res) => {
    try {
      const { pathname } = new URL(req.url, "http://localhost");
      if (pages.has(pathname)) {
        res.writeHead(200, { "content-type": "text/html" });
        return res.end(pages.get(pathname));
      }
      const file = path.join(REPO, decodeURIComponent(pathname));
      // Everything served is inside the repo; nothing here should escape it.
      if (!file.startsWith(REPO)) {
        res.writeHead(403);
        return res.end("forbidden");
      }
      const body = await fs.promises.readFile(file);
      res.writeHead(200, { "content-type": MIME[path.extname(file)] ?? "application/octet-stream" });
      res.end(body);
    } catch {
      res.writeHead(404);
      res.end("not found");
    }
  });
}

// ---------------------------------------------------------------- run

const cases = await loadCases(findCases());
if (!cases.length) die("no model package has test/browser-case.js");

// A stub dist cannot run inference, so say so before launching anything.
const missing = cases.filter((c) => !fs.existsSync(path.join(c.dir, "dist")));
if (missing.length) {
  die(`no dist/ for ${missing.map((c) => c.model).join(", ")}; run \`mise run build:wasm\` first`);
}

// DAL_BROWSER_ENGINE=webkit (or firefox) runs the cases in that engine instead: Safari's
// LiteRT.js path differs from Chromium's (no JSPI), so it is worth its own run.
const ENGINE = process.env.DAL_BROWSER_ENGINE ?? "chromium";
let engine;
try {
  engine = (await import("playwright"))[ENGINE];
} catch {
  die("playwright is not installed; run `npm install` at the repo root");
}
if (!engine) die(`unknown DAL_BROWSER_ENGINE "${ENGINE}" (chromium, webkit, firefox)`);

const pages = new Map(cases.map((c) => [`/__browser-test__/${c.model}`, renderPage(c)]));
const server = serve(pages);
await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(PORT, resolve);
});

// GPU flags for every case, not just the ones that need them. LiteRT.js runs on
// wasm here and does not care; Voz compiles its encoder for WebGPU and its
// decode step for WebNN, and headless Chromium exposes neither without being
// asked. A real adapter rather than the software one is what makes a timing
// number meaningful: ANGLE's Metal backend gets one on macOS; a Linux runner
// has no Metal and needs Vulkan, falling back to SwiftShader when the runner
// has no GPU at all. Naming the wrong one is not fatal (Chromium ignores it)
// but naming the right one is the difference between a real adapter and none.
// DAL_BROWSER_SOFTWARE=1 forces the software adapter, which is what a runner
// with no GPU has: it is how the no-GPU path gets tested from a machine that
// does have one.
const gpuArgs = process.env.DAL_BROWSER_SOFTWARE === "1"
  ? ["--enable-unsafe-swiftshader", "--use-angle=swiftshader", "--disable-gpu"]
  : process.platform === "darwin"
    ? ["--use-angle=metal"]
    : ["--use-angle=vulkan", "--enable-unsafe-swiftshader"];
const browser = await engine.launch({
  headless: !args.includes("--headed"),
  args: ENGINE !== "chromium" ? [] : [
    "--enable-unsafe-webgpu",
    "--enable-features=WebNN,WebMachineLearningNeuralNetwork",
    ...gpuArgs,
    "--ignore-gpu-blocklist",
    "--enable-gpu",
  ],
});
const failures = [];

const pageGlobals = Object.fromEntries([
  ["__dalHfRepoSuffix", process.env.DAL_HF_REPO_SUFFIX],
  ["__dalHfToken", process.env.HF_TOKEN],
  ["__dalLicenseEndpoint", process.env.DAL_LICENSE_ENDPOINT],
].filter(([, value]) => value));

const LICENSE_PATH = "/__license__/api/v1";
const outages = {
  unavailable: (route) => route.fulfill({
    status: 503,
    headers: { "retry-after": "3600" },
    contentType: "application/json",
    body: '{"error":"retry"}',
  }),
  silent: () => {},
};

function sameText(a, b) {
  if (typeof a === "number" && typeof b === "number") return true;
  if (Array.isArray(a) && Array.isArray(b)) return a.length === b.length && a.every((x, i) => sameText(x, b[i]));
  if (a && b && typeof a === "object" && typeof b === "object") {
    const keys = Object.keys(a);
    return sameText(keys, Object.keys(b)) && keys.every((k) => sameText(a[k], b[k]));
  }
  return a === b;
}

function waitAtMost(promise, ms) {
  let timer;
  const expired = new Promise((resolve) => (timer = setTimeout(resolve, ms)));
  return Promise.race([promise, expired]).finally(() => clearTimeout(timer));
}

async function runPage(entry, context, outage) {
  const tab = await context.newPage();
  const globals = outage
    ? { ...pageGlobals, __dalLicenseEndpoint: `http://localhost:${PORT}${LICENSE_PATH}` }
    : pageGlobals;
  await tab.addInitScript((g) => Object.assign(globalThis, g), globals);
  const label = outage ? `${entry.model}, license ${outage}` : entry.model;
  const logs = [];
  const errors = [];
  tab.on("console", (m) => logs.push(`[${label}] ${m.text()}`));
  tab.on("pageerror", (e) => {
    errors.push(e.message);
    logs.push(`[${label}] pageerror: ${e.message}`);
  });
  const license = { requests: 0 };
  const licenseRequested = new Promise((resolve) => (license.seen = resolve));
  if (outage) {
    await tab.route(`**${LICENSE_PATH}/**`, (route) => {
      license.requests += 1;
      license.seen();
      outages[outage](route);
    });
  }

  try {
    await tab.goto(`http://localhost:${PORT}/__browser-test__/${entry.model}`);
    const handle = await tab.waitForFunction(
      () => window.__result || window.__error,
      null,
      { timeout: TIMEOUT_MS },
    );
    // window.__error is a string, window.__result an object: the page reports a
    // failure inside the model rather than as a harness timeout.
    const value = await handle.jsonValue();
    if (typeof value === "string") throw new Error(value);
    if (outage) await waitAtMost(licenseRequested, 10_000);
    if (outage && errors.length) throw new Error(`license ${outage}: the page threw ${errors.join("; ")}`);
    return { ...value, licenseRequests: license.requests };
  } catch (error) {
    const detail = await tab.evaluate(() => window.__error).catch(() => null);
    logs.forEach((l) => console.error(l));
    throw new Error(detail ?? error.message);
  } finally {
    await tab.close();
  }
}

let outageCasesRan = 0;
for (const entry of cases) {
  const context = await browser.newContext();
  try {
    const baseline = await runPage(entry, context, null);
    // The case owns its own assertion, so the harness stays model-agnostic.
    entry.module.check(baseline.result);
    log(`ok   ${entry.model}  (${baseline.ms} ms in browser)  ${JSON.stringify(baseline.result).slice(0, 120)}`);

    // A license server that answers 503 or never answers must change neither
    // the output nor the time. Only for the cases that opted in: see the top
    // comment for why this is per runtime, not per model.
    if (entry.module.checksLicense) {
      outageCasesRan += 1;
      const runs = {};
      for (const outage of Object.keys(outages)) {
        const run = await runPage(entry, context, outage);
        entry.module.check(run.result);
        if (!run.licenseRequests) throw new Error(`license ${outage}: the page sent no license request`);
        if (!sameText(run.result, baseline.result)) {
          throw new Error(`license ${outage}: the output changed to ${JSON.stringify(run.result).slice(0, 200)}`);
        }
        runs[outage] = run;
        log(`ok   ${entry.model}  license ${outage}  (${run.ms} ms in browser)`);
      }
      if (runs.silent.ms - runs.unavailable.ms > 5000) {
        throw new Error(`license silent: the page took ${runs.silent.ms} ms against ${runs.unavailable.ms} ms`);
      }
    }
  } catch (error) {
    failures.push(`${entry.model}: ${error.message}`);
  } finally {
    await context.close();
  }
}

await browser.close();
server.close();

// --only narrows the run on purpose; a full run with no outage coverage means
// every checksLicense flag went missing, which must fail rather than pass quietly.
if (!only && cases.length && !outageCasesRan) {
  failures.push("no case exports checksLicense, so the license outage path went untested");
}

if (failures.length) {
  console.error(`\n${failures.length} of ${cases.length} browser cases failed:`);
  for (const f of failures) console.error(`  ${f}`);
  process.exit(1);
}
log(`\nall ${cases.length} models ran inference in the browser`);
