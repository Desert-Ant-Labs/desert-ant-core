// The shared browser/WebAssembly runtime for the model node packages: it owns
// the @litertjs/core (LiteRT.js) session behind the generic tensor contract the
// wasm core (JSInferenceSession) calls, loads LiteRT.js once per process, and
// carries the browser half of the platform seam. A model package supplies only
// its host-global name, its dist entry points, and its self-hosted file names.
//
// Browser-safe: no `node:*` imports. The node-only native path lives in
// node.js.

// @litertjs/core is loaded once per process; its Wasm runtime initializes a
// single time. `loadLiteRt` memoizes both the module import and the runtime
// load across every model in the process (LiteRT.js is itself a singleton).
let liteRtReady;

async function importLiteRt(packageName) {
  try {
    return await import("@litertjs/core");
  } catch (cause) {
    // Only surface the install hint when @litertjs/core is genuinely absent;
    // rethrow anything else (a real error from inside LiteRT.js) unchanged.
    const missing =
      cause?.code === "ERR_MODULE_NOT_FOUND" ||
      cause?.code === "MODULE_NOT_FOUND" ||
      String(cause?.message ?? "").includes("@litertjs/core");
    if (!missing) throw cause;
    throw new Error(
      `${packageName} browser runtime requires @litertjs/core. ` +
        `Install it with: npm i ${packageName} @litertjs/core. ` +
        `If you already bundle LiteRT.js yourself, pass it to load({ litert }). ` +
        `(In Node, import the package normally to use the native server-side build instead.)`,
      { cause },
    );
  }
}

/**
 * Load @litertjs/core and ensure its Wasm runtime is initialized (once per
 * process). Returns the LiteRT.js module ({ loadAndCompile, Tensor, ... }).
 *
 * @param {object} o
 * @param {any} [o.litert] caller-injected module (tests/custom builds)
 * @param {string} [o.wasmDir] explicit runtime directory (overrides default)
 * @param {() => Promise<string>} o.defaultWasmDir where LiteRT.js loads its wasm
 * @param {string} o.packageName consumer package name for the install hint
 */
export async function loadLiteRt({ litert, wasmDir, defaultWasmDir, packageName }) {
  const lrt = litert ?? (await importLiteRt(packageName));
  liteRtReady ??= lrt.loadLiteRt(wasmDir ?? (await defaultWasmDir()));
  await liteRtReady;
  return lrt;
}

/**
 * LiteRT.js loads its Wasm runtime through the DOM (a <script> tag) or a Web
 * Worker (importScripts); it has no plain-Node loader. So the default (wasm)
 * build can be imported during SSR but cannot run inference in Node. Detect that
 * up front and point at the native server build instead of failing deep inside
 * LiteRT.js with a cryptic `document is not defined`.
 */
export function assertBrowserRuntime({ packageName, litert }) {
  if (litert) return; // caller injected a working module; trust it
  const hasDom = typeof document !== "undefined";
  const hasWorker = typeof importScripts === "function";
  if (hasDom || hasWorker) return;
  throw new Error(
    `${packageName}: the default import runs the browser WebAssembly runtime ` +
      `(LiteRT.js), which needs a browser/Worker environment and can't ` +
      `initialize in plain Node. For server-side inference import the native ` +
      `build instead: import from "${packageName}/native". (The default import ` +
      `is still safe to bundle for server-side rendering; only calling load() ` +
      `in Node needs the native build.)`,
  );
}

/**
 * Install the LiteRT.js host the wasm core (JSInferenceSession) drives through
 * `globalThis[hostGlobal]`. Both sides exchange named tensors as
 * `{ name: { data: Uint8Array, dims: number[], type } }`; LiteRT.js infers each
 * dtype from the typed array. Uses LiteRT.js manual memory management: results
 * and any GPU->wasm copies are deleted along with the input tensors made here.
 *
 * Returns `{ setModel }` so the caller's `modelBaseUrl` opt-out can compile the
 * model directly and hand it to the same `run` closure.
 *
 * @param {object} o
 * @param {string} o.hostGlobal e.g. "__ShapesHost"
 * @param {string} o.accelerator "wasm" (default) or "webgpu"
 * @param {(data: Uint8Array, opts: object) => Promise<any>} o.loadAndCompile
 * @param {new (data: any, dims: number[]) => any} o.Tensor
 * @param {(source: any) => Promise<any>} o.readModelSource path (node) -> bytes
 */
export function installLiteRtHost({ hostGlobal, accelerator = "wasm", loadAndCompile, Tensor, readModelSource }) {
  let model;

  const typedArray = (t) => {
    const bytes = t.data.slice(); // own, aligned buffer
    switch (t.type) {
      case "int32":
        return new Int32Array(bytes.buffer);
      case "float32":
        return new Float32Array(bytes.buffer);
      case "uint8":
        return new Uint8Array(bytes.buffer);
      default:
        throw new Error(`unsupported tensor type: ${t.type}`);
    }
  };

  globalThis[hostGlobal] = {
    // modelSource is the cached file path (node) or the model bytes (browser).
    createSession: async (modelSource) => {
      const modelData = await readModelSource(modelSource);
      model = await loadAndCompile(modelData, { accelerator });
    },
    run: async (inputs) => {
      const feeds = {};
      const made = [];
      for (const [name, t] of Object.entries(inputs)) {
        const tensor = new Tensor(typedArray(t), Array.from(t.dims));
        feeds[name] = tensor;
        made.push(tensor);
      }
      const results = await model.run(feeds);
      const outputs = {};
      const toDelete = [...made];
      for (const [name, out] of Object.entries(results)) {
        const host = accelerator === "wasm" ? out : await out.moveTo("wasm");
        const arr = host.toTypedArray();
        outputs[name] = {
          data: new Uint8Array(arr.buffer.slice(arr.byteOffset, arr.byteOffset + arr.byteLength)),
          dims: Array.from(host.type.layout.dimensions),
          type: host.type.dtype,
        };
        toDelete.push(out);
        if (host !== out) toDelete.push(host);
      }
      for (const t of toDelete) t.delete();
      return outputs;
    },
  };

  return {
    setModel: (m) => {
      model = m;
    },
  };
}

/**
 * Fetch self-hosted model files from a base URL (the `modelBaseUrl` opt-out).
 * Accepts absolute URLs and root-relative paths (e.g. "/assets/shapes/").
 *
 * @param {string} baseUrl
 * @param {{ meta: string, model: string }} files file names under baseUrl,
 *   e.g. { meta: "shapes_meta.json", model: "shapes.tflite" }
 * @returns {Promise<{ metaJSON: string, modelBytes: Uint8Array }>}
 */
export async function fetchModelFrom(baseUrl, files) {
  const base = baseUrl.endsWith("/") ? baseUrl : `${baseUrl}/`;
  const [meta, model] = await Promise.all([
    fetch(`${base}${files.meta}`).then((r) => r.text()),
    fetch(`${base}${files.model}`).then((r) => r.arrayBuffer()),
  ]);
  return { metaJSON: meta, modelBytes: new Uint8Array(model) };
}

// ------------------------------------------------------------- browser seam
//
// The browser half of a model package's `#platform` import. A model's
// platform-browser.js is a thin wrapper around these.

/** Instantiate the wasm core and return its exports global. `init` imports the
 *  model's own ./dist/index.js. */
export async function browserSetup({ hostGlobal, exportsGlobal, init }) {
  globalThis[hostGlobal] ??= {};
  const { init: initCore } = await init();
  await initCore({});
  return globalThis[exportsGlobal];
}

/** Where LiteRT.js loads its Wasm runtime from in the browser: the jsDelivr
 *  mirror of the @litertjs/core package's wasm/ directory. */
export async function browserWasmDir() {
  return "https://cdn.jsdelivr.net/npm/@litertjs/core/wasm/";
}

/** In the browser the model "source" is already the model bytes. */
export async function browserReadModelSource(source) {
  return source;
}

/** No managed on-disk cache in the browser; the runtime caches (Cache API /
 *  IndexedDB) with an empty base. */
export async function browserCacheRoot() {
  return "";
}
