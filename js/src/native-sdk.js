// The native (server-side Node) half of a model package, mirroring
// `createWasmSdk`: bind the prebuilt Swift core with koffi, normalize its
// `dal_*` symbols to the core shape `LoadedModel` uses, and hand back an
// `open(options)` that returns a ready model.
//
// The normalization is the whole point: after it, a package's native entry and
// its browser entry drive an identical object, so the public class is written
// once per model instead of once per runtime.
//
// Node-only (loadNative uses node:* + koffi).
import { loadNative } from "./native.js";
import { readyModel } from "./sdk.js";

/**
 * @param {object} o
 * @param {string} o.here directory of the package's node.js (import.meta dir)
 * @param {string} o.packageName consumer package (for error messages)
 * @param {string} o.modelId catalog id, e.g. "emo"
 * @param {string} o.coreName the package's native library base name (e.g. "EmoNode")
 */
export function createNativeSdk({ here, packageName, modelId, coreName }) {
  // The prebuilt native for this host lives in native/<platform>-<arch>/ next to
  // the package's node.js (built by `mise run node-natives`): the self-contained
  // model-specific Swift library plus the LiteRT runtime it links. The ABI is
  // the same for every model apart from the `<modelId>_create` constructor, so
  // no symbol is named here.
  const native = loadNative({ here, packageName, coreName, modelId });
  const { lib, callAsync, decodeResult, withCallGroup } = native;

  const isDownloaded = (handle) => lib.isDownloaded(handle) !== 0;

  // Plain closures rather than `this`-dependent methods: the core is handed
  // around as a value (LoadedModel, readyModel), so it must survive destructuring.
  const core = {
    // Managed nested cache under ~/.cache by default (matching the browser
    // host); an explicit `directory` is adopted when it holds the files, else
    // downloaded into.
    create: (cacheRoot, directory) => lib.create(modelId, cacheRoot, directory || null),
    isDownloaded,
    async download(handle, onProgress) {
      // The C ABI has no progress channel: report the endpoints so a caller's
      // onProgress behaves the same on both runtimes.
      if (isDownloaded(handle)) return;
      onProgress?.(0);
      const rc = await callAsync(lib.download, handle);
      if (rc !== 0) throw new Error("the native core reported a download failure");
    },
    async run(handle, text, options, group, deviceId) {
      const payload = options ?? new Uint8Array();
      const ptr = await callAsync(
        lib.run, handle, text, payload, payload.length, group, deviceId);
      if (!ptr) throw new Error(`${packageName}: the model failed to run`);
      try {
        return decodeResult(ptr);
      } finally {
        lib.bufferFree(ptr);
      }
    },
    destroy: (handle) => lib.destroy(handle),
    withCallGroup,
  };

  return {
    core,
    async open(options = {}) {
      const onProgress = typeof options.onProgress === "function" ? options.onProgress : undefined;
      const cacheRoot = options.cacheRoot ?? native.defaultCacheRoot();
      const handle = core.create(cacheRoot, options.directory ?? null);
      return readyModel({ core, packageName, handle, onProgress });
    },
  };
}
