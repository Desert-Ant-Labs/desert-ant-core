// The shared server-side native loader for the model node packages: it resolves
// the per-host prebuilt Swift core under native/<platform>-<arch>, loads the
// LiteRT runtime first (so the core's DT_NEEDED resolves in-process), binds the
// `dal_*` C ABI with koffi, and runs blocking calls on a libuv worker thread.
//
// Each package ships a model-specific native library so text models do not pull
// unrelated models or optional capabilities into their binary. Every library
// implements the same C symbols and identifies its one model by `modelId`.
//
// Node-only (uses node:*, koffi). Browser code never imports this file.
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { FfiReader } from "./ffi.js";
import { makeCallGroups, CALL_GROUP_END_SYMBOL } from "./callgroup.js";

const require = createRequire(import.meta.url);

// koffi is loaded lazily (only when a native library is actually loaded), so
// loadNative()/nativeDir() work in environments without the optional koffi peer.
let _koffi;
function koffiModule() {
  return (_koffi ??= require("koffi"));
}

// LiteRT is model-agnostic. The Swift native library name is supplied by each
// model package and all libraries expose the same ABI.
const RUNTIME = { linux: "libLiteRt.so", darwin: "libLiteRt.dylib", win32: "LiteRt.dll" };
const coreFile = (name) => ({ linux: `lib${name}.so`, darwin: `lib${name}.dylib`, win32: `${name}.dll` });

/**
 * The C ABI every model-specific native library implements. Everything but the
 * constructor is generic, since options in and results out are FFI payloads
 * whose schema belongs to the model. The constructor is named per model
 * (`emo_create`) so two models can also be linked into one binary.
 */
export const dalSymbols = (modelId) => ({
  create: `void* ${modelId}_create(const char*, const char*, const char*)`,
  isDownloaded: "int dal_is_downloaded(void*)",
  download: "int dal_download(void*)",
  // One entry for every modality: the input is the model's own payload, like the
  // options and the result. A video model needs no new symbol here.
  run: "void* dal_run(void*, const uint8_t*, int, const uint8_t*, int, const char*, const char*)",
  destroy: "void dal_destroy(void*)",
  // Debug-only (DAL_HTTP_DEBUG): force pending usage telemetry out and block
  // until the sends finish.
  flushTelemetry: "void dal_flush_telemetry()",
  bufferFree: "void dal_buffer_free(void*)",
});

/**
 * Load and bind the prebuilt native core for this host.
 *
 * @param {object} o
 * @param {string} o.here directory of the model's node.js (import.meta dir)
 * @param {string} o.packageName consumer package (for error messages)
 * @param {string} o.coreName the package's native library base name (e.g. "EmoNode")
 * @param {string} o.modelId catalog id, which also prefixes the constructor symbol
 * @param {Record<string,string>} [o.symbols] koffi prototypes keyed by a friendly
 *   name; defaults to this model's ABI ({@link dalSymbols})
 * @param {string[]} [o.targets] supported target keys for the error hint
 * @returns {{ lib: Record<string,any>, koffi: any, callAsync: Function,
 *   decodeResult: (ptr:any)=>FfiReader, version: string,
 *   nativeDir: ()=>string, defaultCacheRoot: ()=>string }}
 */
export function loadNative({ here, packageName, coreName, modelId, symbols, targets }) {
  if (!coreName) throw new Error(`${packageName}: loadNative needs the native library's coreName`);
  if (!symbols && !modelId) throw new Error(`${packageName}: loadNative needs a modelId`);
  symbols ??= dalSymbols(modelId);
  const version = JSON.parse(fs.readFileSync(path.join(here, "package.json"), "utf8")).version;
  const supported = (targets ?? ["linux-x64", "linux-arm64", "darwin-arm64"]).join(", ");

  function nativeDir() {
    const key = `${process.platform}-${process.arch}`;
    const dir = path.join(here, "native", key);
    if (!fs.existsSync(dir)) {
      throw new Error(
        `${packageName}: no prebuilt native for ${key}. ` +
          `Supported server-side targets: ${supported}. ` +
          `Use the Swift package or a browser on this platform.`,
      );
    }
    return dir;
  }

  // Without /sys/devices/system/cpu the CPU backend cannot count cores on arm64
  // and every inference fails, though the library loads fine. Caught here so it
  // reads as a setup problem rather than "the model failed to run".
  function checkCpuTopology(dir) {
    if (process.platform !== "linux" || process.arch !== "arm64") return;
    // Read rather than stat: the shim answers open, so a successful read is the
    // only proof it is really loaded. Checking LD_PRELOAD for the name instead
    // would accept a typo'd or wrong-arch path and hand back the opaque failure.
    try {
      if (fs.readFileSync("/sys/devices/system/cpu/present", "utf8").trim()) return;
    } catch {}
    const shim = path.join(dir, "libdalcpushim.so");
    throw new Error(
      `${packageName}: this host does not mount /sys/devices/system/cpu, which the ` +
        `CPU backend needs to enumerate cores on arm64 (AWS Lambda is one such host). ` +
        `Set LD_PRELOAD=${shim} to preload the shim bundled with this package, ` +
        `or run on x86_64, which does not need it.`,
    );
  }

  const CORE = coreFile(coreName);
  let lib;
  function loadLib() {
    if (lib) return lib;
    const koffi = koffiModule();
    const dir = nativeDir();
    checkCpuTopology(dir);
    // Load the LiteRT runtime first so the core's DT_NEEDED resolves in-process.
    const runtime = RUNTIME[process.platform];
    if (runtime && fs.existsSync(path.join(dir, runtime))) koffi.load(path.join(dir, runtime));
    const core = koffi.load(path.join(dir, CORE[process.platform] || CORE.linux));
    lib = {};
    for (const [name, proto] of Object.entries(symbols)) lib[name] = core.func(proto);
    // Export the generic call-group
    // release symbol; bind it here so `withCallGroup` works without each SDK
    // declaring it.
    lib.dalCallGroupEnd ??= core.func(CALL_GROUP_END_SYMBOL);
    return lib;
  }

  // Run a blocking native function on a libuv worker thread (koffi async) so the
  // Node event loop stays free during download and inference.
  function callAsync(fn, ...args) {
    return new Promise((resolve, reject) => {
      fn.async(...args, (err, res) => (err ? reject(err) : resolve(res)));
    });
  }

  // Decode a native result pointer: a big-endian uint32 length prefix, then the
  // FFIBuffer payload. Returns a reader positioned at the payload start; the
  // caller frees the pointer (e.g. via the core's *_string_free).
  function decodeResult(ptr) {
    const koffi = koffiModule();
    const head = Uint8Array.from(koffi.decode(ptr, koffi.array("uint8", 4)));
    const len = new DataView(head.buffer).getUint32(0, false);
    const full = Uint8Array.from(koffi.decode(ptr, koffi.array("uint8", 4 + len)));
    return new FfiReader(full.subarray(4));
  }

  function defaultCacheRoot() {
    return path.join(os.homedir(), ".cache");
  }

  // The single managed cache layout - <cacheRoot>/desert-ant-models/<repo>/<revision>
  // - is owned by desert-ant-core's Swift ModelStore. The Node entry passes
  // cacheRoot (defaultCacheRoot below) and a null directory, so there is no
  // JS-side model-path computation.

  // Reusable call-group API: mint an id, run the body, release the native group.
  // A logical operation wraps several `{ group }` calls to bill them as one.
  const { withCallGroup } = makeCallGroups((id) => loadLib().dalCallGroupEnd(id));

  return {
    get koffi() {
      return koffiModule();
    },
    lib: new Proxy({}, { get: (_t, prop) => loadLib()[prop] }),
    callAsync,
    decodeResult,
    withCallGroup,
    version,
    nativeDir,
    defaultCacheRoot,
  };
}
