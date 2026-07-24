// The node half of a model package's `#platform` import, for the universal
// WebAssembly entry running server-side (e.g. the Client-Component SSR pass a
// framework renders in Node). Every node-only import lives here so the browser
// bundle never sees `node:*`. A model's platform-node.js is a thin wrapper
// around these.
//
// Node-only (uses node:*).

/**
 * Instantiate the wasm core under Node (WASI shim) and return its exports.
 * Gives the Swift ModelStore node's fs through the shared `__DalNodeFS` seam
 * (no `require` under the WASI shim); the download/verify/cache logic stays in
 * Swift.
 *
 * @param {object} o
 * @param {string} o.hostGlobal e.g. "__ShapesHost"
 * @param {string} o.exportsGlobal e.g. "__ShapesExports"
 * @param {() => Promise<{ instantiate: Function }>} o.instantiate imports the
 *   model's own ./dist/instantiate.js
 * @param {() => Promise<{ defaultNodeSetup: Function }>} o.nodePlatform imports
 *   the model's own ./dist/platforms/node.js
 */
export async function nodeSetup({ hostGlobal, exportsGlobal, instantiate, nodePlatform }) {
  globalThis[hostGlobal] ??= {};
  const { instantiate: inst } = await instantiate();
  const fsmod = await import("node:fs");
  globalThis.__DalNodeFS = {
    existsSync: fsmod.existsSync,
    statSync: fsmod.statSync,
    // Copy into an exact-length Uint8Array: node returns pooled Buffers for
    // small files whose .buffer is the whole shared pool, which JavaScriptKit
    // would over-read when marshalling into wasm memory.
    readFileSync: (p) => new Uint8Array(fsmod.readFileSync(p)),
    writeFileSync: fsmod.writeFileSync,
    mkdirSync: fsmod.mkdirSync,
    renameSync: fsmod.renameSync,
    unlinkSync: fsmod.unlinkSync,
  };
  const { defaultNodeSetup } = await nodePlatform();
  await inst(await defaultNodeSetup({}));
  return globalThis[exportsGlobal];
}

/**
 * Serve LiteRT.js's own Wasm runtime straight from the installed @litertjs/core
 * package. Layout: <root>/dist/index.js and <root>/wasm/. Walk up from the
 * resolved entry to the package root, then point at wasm/.
 */
export async function nodeWasmDir() {
  const { createRequire } = await import("node:module");
  const { pathToFileURL } = await import("node:url");
  const path = await import("node:path");
  const fs = await import("node:fs");
  const require = createRequire(import.meta.url);
  let dir = path.dirname(require.resolve("@litertjs/core"));
  for (let i = 0; i < 4 && !fs.existsSync(path.join(dir, "wasm")); i++) {
    dir = path.dirname(dir);
  }
  return pathToFileURL(path.join(dir, "wasm") + "/").href;
}

/** The wasm host hands createSession a cached file path under Node; read it into
 *  an owned Uint8Array before compiling. */
export async function nodeReadModelSource(source) {
  if (typeof source === "string") {
    const fs = await import("node:fs");
    return new Uint8Array(fs.readFileSync(source));
  }
  return source;
}

/** Base for the managed nested cache under Node: ~/.cache. */
export async function nodeCacheRoot() {
  const os = await import("node:os");
  const path = await import("node:path");
  return path.join(os.homedir(), ".cache");
}
