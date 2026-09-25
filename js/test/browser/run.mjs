#!/usr/bin/env node
// Browser inference: run every model's real browser path in headless Chromium.
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
// case that needs a runtime of its own says so by exporting `imports`, a list
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
    .filter((p) => fs.existsSync(path.join(p.dir, "test", "browser-case.js")))
    .filter((p) => !only || only.includes(p.model))
    .sort((a, b) => a.model.localeCompare(b.model));
}

/** Load each case in Node, for the `imports` it declares and the `check` it
 *  runs afterwards. Top-level code in a case must therefore be Node-safe,
 *  which is why a case imports a browser runtime inside `run`. */
async function loadCases(entries) {
  return Promise.all(entries.map(async (entry) => ({
    ...entry,
    module: await import(pathToFileURL(path.join(entry.dir, "test", "browser-case.js"))),
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
<script>
  // The page opt-out plus a loopback ingest; the harness fails the run on any ingest request.
  globalThis.__dalUsageDisabled = true;
  globalThis.__dalIngestEndpoint = "http://127.0.0.1:9/api/v1/ingest";
</script>
<script type="module">
  import { run } from "${caseDir}/browser-case.js";

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

let chromium;
try {
  ({ chromium } = await import("playwright"));
} catch {
  die("playwright is not installed; run `npm install` at the repo root");
}

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
const browser = await chromium.launch({
  headless: !args.includes("--headed"),
  args: [
    "--enable-unsafe-webgpu",
    "--enable-features=WebNN,WebMachineLearningNeuralNetwork",
    ...gpuArgs,
    "--ignore-gpu-blocklist",
    "--enable-gpu",
  ],
});
const failures = [];

// Any request to the usage ingest fails the run, and is aborted so nothing is sent.
const ingestHits = [];
const INGEST_HOSTS = /(^|\.)events\.desertant\.com$/;

for (const entry of cases) {
  const tab = await browser.newPage();
  await tab.route(
    (url) => INGEST_HOSTS.test(url.hostname),
    (route) => {
      ingestHits.push(`${entry.model}: ${route.request().method()} ${route.request().url()}`);
      return route.abort();
    },
  );
  const logs = [];
  tab.on("console", (m) => logs.push(`[${entry.model}] ${m.text()}`));
  tab.on("pageerror", (e) => logs.push(`[${entry.model}] pageerror: ${e.message}`));

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

    // The case owns its own assertion, so the harness stays model-agnostic.
    entry.module.check(value.result);
    log(`ok   ${entry.model}  (${value.ms} ms in browser)  ${JSON.stringify(value.result).slice(0, 120)}`);
  } catch (error) {
    const detail = await tab.evaluate(() => window.__error).catch(() => null);
    failures.push(`${entry.model}: ${detail ?? error.message}`);
    logs.forEach((l) => console.error(l));
  } finally {
    await tab.close();
  }
}

await browser.close();
server.close();

for (const hit of ingestHits) failures.push(`usage reached the real ingest: ${hit}`);

if (failures.length) {
  console.error(`\n${failures.length} of ${cases.length} browser cases failed:`);
  for (const f of failures) console.error(`  ${f}`);
  process.exit(1);
}
log(`\nall ${cases.length} models ran inference in the browser`);
