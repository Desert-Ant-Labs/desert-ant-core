// On-device __DESCRIPTION_SHORT__ for JavaScript, server-side (Node). Runs the same
// pipeline as the browser build, natively via the prebuilt Swift core. The koffi
// harness and FFI decode live in @desert-ant-labs/core/node; this file supplies
// the C ABI, the decode, and the public API.
import { fileURLToPath } from "node:url";
import path from "node:path";
import { loadNative } from "@desert-ant-labs/core/node";

const HERE = path.dirname(fileURLToPath(import.meta.url));

const core = loadNative({
  here: HERE,
  packageName: "@desert-ant-labs/__MODEL__",
  coreName: "__PRODUCT__Node",
  symbols: {
    create: "void* __MODEL___create(const char*, const char*)",
    isDownloaded: "int __MODEL___is_downloaded(void*)",
    download: "int __MODEL___download(void*)",
    run: "void* __MODEL___run(void*, const char*, double)",
    destroy: "void __MODEL___destroy(void*)",
    stringFree: "void __MODEL___string_free(void*)",
  },
});
const { lib, callAsync, decodeResult } = core;

/** Decode the FFI payload. Keep in sync with `__MODEL___run` in CABI.swift. */
function decode(r) {
  if (r.u32() === 0) return null;
  return { label: r.str(), confidence: r.f64() };
}

/** On-device __DESCRIPTION_SHORT__. Create one with `await __PRODUCT__.load(...)`. */
export class __PRODUCT__ {
  #handle;
  constructor(handle) { this.#handle = handle; }

  static async load(options = {}) {
    const onProgress = typeof options.onProgress === "function" ? options.onProgress : undefined;
    const cacheRoot = options.cacheRoot ?? core.defaultCacheRoot();
    const directory = options.directory ?? null;
    const handle = lib.create(cacheRoot, directory);
    if (!handle) throw new Error("@desert-ant-labs/__MODEL__: failed to create __PRODUCT__");
    const instance = new __PRODUCT__(handle);
    if (lib.isDownloaded(handle) === 0) {
      onProgress?.(0);
      const rc = await callAsync(lib.download, handle);
      if (rc !== 0) { instance.dispose(); throw new Error("@desert-ant-labs/__MODEL__: model download failed"); }
    }
    onProgress?.(1);
    return instance;
  }

  async run(input, options = {}) {
    if (!this.#handle) throw new Error("@desert-ant-labs/__MODEL__: disposed");
    const ptr = await callAsync(lib.run, this.#handle, String(input ?? ""), options.minimumConfidence ?? 0);
    if (!ptr) return null;
    try { return decode(decodeResult(ptr)); } finally { lib.stringFree(ptr); }
  }

  /** Free the native handle. */
  dispose() {
    if (this.#handle) { lib.destroy(this.#handle); this.#handle = null; }
  }
}
