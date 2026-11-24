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
import { flushNative, loadNative } from "./native.js";
import { registerFlush } from "./configure.js";
import { readyModel } from "./sdk.js";

const NATIVE_STARTED = Symbol.for("desert-ant-labs.native-started");

/**
 * The native core reads its host settings from the environment (DAL_APP_ID,
 * DAL_LICENSE_ENDPOINT); the browser entry reads the same values from
 * `globalThis.__dal*`. Bridging them means a
 * host sets one spelling on either runtime. Each may be a string or a zero-arg
 * function, the two forms the core's own JS host read accepts. An environment
 * variable already set wins.
 *
 * Run at each load rather than once at import, so a host that imports the package
 * before setting the global is still picked up, but only until a native model
 * first loads in this process: from then on core threads read the environment,
 * and `setenv` racing a `getenv` is a use-after-free on glibc. An app id or
 * endpoint set after the first load has to be in the environment already. The
 * API key comes from `DesertAnt.configure` instead.
 */
function bridgeHostIdentity() {
  if (globalThis[NATIVE_STARTED]) return;
  for (const [name, env] of [
    ["__dalAppId", "DAL_APP_ID"],
    ["__dalLicenseEndpoint", "DAL_LICENSE_ENDPOINT"],
  ]) {
    let value;
    try {
      const raw = globalThis[name];
      value = typeof raw === "function" ? raw() : raw;
    } catch {
      continue;
    }
    if (typeof value === "string" && value && !process.env[env]) process.env[env] = value;
  }
}

/**
 * @param {object} o
 * @param {string} o.here directory of the package's node.js (import.meta dir)
 * @param {string} o.packageName consumer package (for error messages)
 * @param {string} o.modelId catalog id, e.g. "emo"
 * @param {string} o.coreName the package's native library base name (e.g. "EmoNode")
 */
export function createNativeSdk({ here, packageName, modelId, coreName }) {
  // The prebuilt native for this host lives in native/<platform>-<arch>/ next to
  // the package's node.js (built by `mise run build:node-native`): the self-contained
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
    // A variant is asked for as `<id>/<variant>` (Face's "face/detector").
    create: (cacheRoot, directory, variant) =>
      lib.create(variant ? `${modelId}/${variant}` : modelId, cacheRoot, directory || null),
    isDownloaded,
    async download(handle, onProgress) {
      // The C ABI has no progress channel: report the endpoints so a caller's
      // onProgress behaves the same on both runtimes.
      if (isDownloaded(handle)) return;
      onProgress?.(0);
      const rc = await callAsync(lib.download, handle);
      if (rc !== 0) throw new Error("the native core reported a download failure");
    },
    async run(handle, input, options, _group, deviceId) {
      const payload = options ?? new Uint8Array();
      const ptr = await callAsync(
        lib.run, handle, input, input.length, payload, payload.length, null, deviceId ?? null);
      if (!ptr) throw new Error(`${packageName}: the model failed to run`);
      try {
        return decodeResult(ptr);
      } finally {
        lib.bufferFree(ptr);
      }
    },
    destroy: (handle) => lib.destroy(handle),
    flushLicenses: () => flushNative(lib, callAsync),
    withCallGroup,
  };

  // Global hook for awaiting the license requests in flight without a model
  // reference, mirroring the wasm entry (`createWasmSdk`). Gated on
  // DAL_HTTP_DEBUG; a host holding a model calls its `flushLicenses()` instead.
  if (process.env.DAL_HTTP_DEBUG) {
    globalThis.__dalFlushLicenses = () => core.flushLicenses();
  }

  return {
    core,
    /** `variant` is another way to run the model, as in `createWasmSdk`. */
    async open(options = {}, { variant } = {}) {
      bridgeHostIdentity();
      const onProgress = typeof options.onProgress === "function" ? options.onProgress : undefined;
      // Only an explicit cacheRoot goes down: Apple and Linux resolve their own
      // caches directory, and the core honours what it is given, so sending a
      // default would relocate every existing cache.
      const handle = core.create(options.cacheRoot ?? null, options.directory ?? null, variant);
      globalThis[NATIVE_STARTED] = true;
      // Registered at the first load: a flush must not load the library of a package that has no model yet.
      registerFlush(core.flushLicenses);
      return readyModel({ core, packageName, handle, onProgress });
    },
  };
}
