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

const NATIVE_STARTED = Symbol.for("desert-ant-labs.native-started");

/** `globalThis.__dalDeviceId`, as a string or a zero-arg function, or null. */
function hostDeviceId() {
  try {
    const raw = globalThis.__dalDeviceId;
    const value = typeof raw === "function" ? raw() : raw;
    return typeof value === "string" && value.trim() ? value.trim() : null;
  } catch {
    // A getter that throws (say, outside a request context) means no host id,
    // not a failed inference.
    return null;
  }
}

/**
 * The native core reads usage identity and settings from the environment
 * (DAL_APP_ID, DAL_API_KEY, DAL_DEVICE_ID, DAL_APP_VERSION,
 * DAL_USAGE_CONTEXT_DISABLED); the browser entry reads the same values from
 * `globalThis.__dal*`. Bridging them means a host sets one spelling on either
 * runtime, and a server that sets the global is not silently unattributed. Each
 * may be a string or a zero-arg function, the two forms the core's own JS host
 * read accepts, and the context flag may also be `true`, as it may in a page.
 * An environment variable already set wins.
 *
 * Run at each load rather than once at import, so a host that imports the package
 * before setting the global is still attributed, but only until a native model
 * first loads in this process: from then on core threads read the environment,
 * and `setenv` racing a `getenv` is a use-after-free on glibc. A device id set
 * later still counts, since `run` passes it per call; a key, app id, app version
 * or context flag set after the first load has to be in the environment already.
 */
function bridgeHostIdentity() {
  if (globalThis[NATIVE_STARTED]) return;
  for (const [name, env] of [
    ["__dalAppId", "DAL_APP_ID"],
    ["__dalApiKey", "DAL_API_KEY"],
    ["__dalDeviceId", "DAL_DEVICE_ID"],
    ["__dalAppVersion", "DAL_APP_VERSION"],
    ["__dalUsageContextDisabled", "DAL_USAGE_CONTEXT_DISABLED"],
  ]) {
    let value;
    try {
      const raw = globalThis[name];
      value = typeof raw === "function" ? raw() : raw;
    } catch {
      continue;
    }
    if (value === true && name === "__dalUsageContextDisabled") value = "1";
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
    async run(handle, input, options, group, deviceId) {
      const payload = options ?? new Uint8Array();
      // Per call rather than through the environment, which is no longer written
      // once a native model has started (see bridgeHostIdentity). The
      // environment still wins, as it does in the bridge.
      const device = deviceId ?? (process.env.DAL_DEVICE_ID ? null : hostDeviceId());
      const ptr = await callAsync(
        lib.run, handle, input, input.length, payload, payload.length, group, device);
      if (!ptr) throw new Error(`${packageName}: the model failed to run`);
      try {
        return decodeResult(ptr);
      } finally {
        lib.bufferFree(ptr);
      }
    },
    destroy: (handle) => lib.destroy(handle),
    // The C symbol is `void`, so resolving it directly would hand a caller
    // `undefined` where the wasm entry resolves `true` and both are declared
    // `Promise<boolean>`. The flush cannot report a partial failure: it either
    // returned or it threw.
    async flushTelemetry() {
      await callAsync(lib.flushTelemetry);
      return true;
    },
    withCallGroup,
  };

  // Global hook for forcing the usage POST out and awaiting it without a model
  // reference, mirroring the wasm entry (`createWasmSdk`). Gated on the same flag
  // the telemetry log itself needs; a host holding a model calls its
  // `flushTelemetry()` instead.
  if (process.env.DAL_HTTP_DEBUG) {
    globalThis.__dalFlushTelemetry = () => core.flushTelemetry();
  }

  return {
    core,
    async open(options = {}) {
      bridgeHostIdentity();
      const onProgress = typeof options.onProgress === "function" ? options.onProgress : undefined;
      // Only an explicit cacheRoot goes down. Apple and Linux resolve their own
      // caches directory, so the default fabricated here was discarded by the
      // core anyway; now that the core honours what it is given, sending one
      // would relocate every existing cache.
      const handle = core.create(options.cacheRoot ?? null, options.directory ?? null);
      globalThis[NATIVE_STARTED] = true;
      return readyModel({ core, packageName, handle, onProgress });
    },
  };
}
