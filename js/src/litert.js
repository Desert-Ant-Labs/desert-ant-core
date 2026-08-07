// The shared browser/WebAssembly runtime for the model node packages: it owns
// the @litertjs/core (LiteRT.js) session behind the generic tensor contract the
// wasm core (JSInferenceSession) calls, loads LiteRT.js once per process, and
// carries the browser half of the platform seam. A model package supplies only
// its dist entry points; everything else about the model comes from the core's
// own `modelInfo()`.
//
// Browser-safe: no `node:*` imports. The node-only native path lives in
// node.js.

// Keep initialization on the global symbol registry rather than in this module.
// That still gives the page one LiteRT runtime if a package manager installs two
// physical copies of @desert-ant-labs/core for different model SDKs.
const liteRtStateKey = Symbol.for("ai.desertant.litert.state");
const liteRtState = (globalThis[liteRtStateKey] ??= {});

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
  liteRtState.ready ??= lrt.loadLiteRt(wasmDir ?? (await defaultWasmDir()));
  await liteRtState.ready;
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
 * The model host a wasm core is instantiated with: `dalModelHost` in the core's
 * generated `Imports` (see `dist/bridge-js.d.ts`, generated from
 * `Sources/JSHost/Host.swift`). The core compiles its model through
 * `createSessionFrom*` and runs it through `run`.
 *
 * It is created before LiteRT.js exists, because a core instantiates at import
 * time and its session only exists once the app calls `load()`. So `imports` is
 * stable and its methods forward to whatever `install` last set - the same late
 * binding a named global used to provide, minus the global.
 *
 * @returns {{ imports: object, install: (host: object) => void }}
 */
export function makeModelHostSeam() {
  let host = null;
  const live = () => {
    if (!host) throw new Error("the model host is not installed yet");
    return host;
  };
  return {
    imports: {
      dalModelHost: {
        // `async` on purpose: the Swift side declares these as `async throws`, so
        // "no host installed" has to arrive as a rejected promise rather than a
        // synchronous throw across the bridge.
        createSessionFromPath: async (path) => live().createSessionFromPath(path),
        createSessionFromBytes: async (bytes) => live().createSessionFromBytes(bytes),
        run: async (inputs) => live().run(inputs),
      },
    },
    install: (implementation) => {
      host = implementation;
    },
  };
}

/**
 * The LiteRT.js implementation of that contract. `setModel` lets the
 * `modelBaseUrl` path hand over a model the page compiled itself, instead of one
 * of the `createSessionFrom*` calls.
 */
export function makeLiteRtHost({ accelerator = "wasm", loadAndCompile, Tensor, readModelSource }) {
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

  return {
    host: {
      // node hands over the cached path, the browser the bytes it fetched: two
      // methods rather than one union, as the typed contract requires.
      createSessionFromPath: async (path) => {
        model = await loadAndCompile(await readModelSource(path), { accelerator });
      },
      createSessionFromBytes: async (bytes) => {
        model = await loadAndCompile(await readModelSource(bytes), { accelerator });
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
    },
    setModel: (m) => {
      model = m;
    },
  };
}

/**
 * Fetch model files an app serves itself (the `modelBaseUrl` option). Accepts
 * absolute URLs and root-relative paths (e.g. "/assets/shapes/").
 *
 * The sidecars come back keyed by their catalog file names, which is what the
 * wasm core's `createSelfHosted` expects; text sidecars stay bytes because the
 * Swift side decodes them itself. The model bytes stay here, for the caller to
 * compile in LiteRT.js: the multi-MB artifact never crosses into wasm.
 *
 * @param {string} baseUrl
 * @param {{ model: string, sidecars: string[] }} files names under baseUrl, e.g.
 *   { model: "shapes.tflite", sidecars: ["shapes_meta.json"] }
 * @returns {Promise<{ sidecars: Record<string, Uint8Array>, modelBytes: Uint8Array }>}
 */
export async function fetchSelfHostedModel(baseUrl, files) {
  const base = baseUrl.endsWith("/") ? baseUrl : `${baseUrl}/`;
  const get = async (name) => new Uint8Array(await fetch(`${base}${name}`).then((r) => r.arrayBuffer()));
  const [modelBytes, ...sidecarBytes] = await Promise.all([
    get(files.model),
    ...files.sidecars.map(get),
  ]);
  const sidecars = {};
  files.sidecars.forEach((name, i) => { sidecars[name] = sidecarBytes[i]; });
  return { sidecars, modelBytes };
}

// ------------------------------------------------------------- browser seam
//
// The browser half of a model package's `#platform` import. A model's
// platform-browser.js is a thin wrapper around these.

/**
 * Instantiate the wasm core: its exports (the model-agnostic wasm ABI, the twin
 * of the native `dal_*` symbols) plus the hook that installs the model host it
 * was instantiated with. Both halves are generated from Swift - the exports from
 * `Sources/WasmBindings/Exports.swift`, the host contract from
 * `Sources/JSHost/Host.swift` - and `init` imports the model's own
 * ./dist/index.js.
 *
 * Everything belongs to this instance, so two SDKs on one page cannot collide and
 * nothing touches `globalThis`.
 */
export async function browserSetup({ init }) {
  const seam = makeModelHostSeam();
  const { init: initCore } = await init();
  const { exports } = await initCore({ getImports: () => seam.imports });
  return { exports, installHost: seam.install };
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
