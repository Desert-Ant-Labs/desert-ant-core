// The shared server-side native loader for the model node packages: it resolves
// the per-host prebuilt Swift core under native/<platform>-<arch>, loads the
// LiteRT runtime first (so the core's DT_NEEDED resolves in-process), binds the
// `dal_*` C ABI with koffi, and runs blocking calls on a libuv worker thread.
//
// There is one native core (DesertAntNode) and one set of C symbols for every
// model: the model is a `modelId` string argument, and its options/results cross
// as FFI payloads it encodes and decodes itself. So a model package supplies no
// symbols and no library name here - only its codecs.
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

// The LiteRT runtime and the Swift core are both model-agnostic: every model
// package loads the same DesertAntNode library (libDesertAntNode.so / .dylib /
// DesertAntNode.dll) built from the Bindings target.
const RUNTIME = { linux: "libLiteRt.so", darwin: "libLiteRt.dylib", win32: "LiteRt.dll" };
const coreFile = (name) => ({ linux: `lib${name}.so`, darwin: `lib${name}.dylib`, win32: `${name}.dll` });

/** The default native core: one library for the whole SDK. */
export const DEFAULT_CORE_NAME = "DesertAntNode";

/**
 * The generic C ABI every model goes through (Sources/Bindings/CABI.swift).
 * `modelId` selects the model, options in and results out are FFI payloads whose
 * schema belongs to the model, so adding a model adds no symbol here.
 */
export const DAL_SYMBOLS = {
  create: "void* dal_create(const char*, const char*, const char*)",
  createFromFiles: "void* dal_create_from_files(const char*, const uint8_t*, int, const char*)",
  isDownloaded: "int dal_is_downloaded(void*)",
  download: "int dal_download(void*)",
  run: "void* dal_run(void*, const char*, const uint8_t*, int, const char*, const char*)",
  destroy: "void dal_destroy(void*)",
  bufferFree: "void dal_buffer_free(void*)",
};

/**
 * Load and bind the prebuilt native core for this host.
 *
 * @param {object} o
 * @param {string} o.here directory of the model's node.js (import.meta dir)
 * @param {string} o.packageName consumer package (for error messages)
 * @param {string} [o.coreName] C core base name; defaults to "DesertAntNode"
 * @param {Record<string,string>} [o.symbols] koffi prototypes keyed by a friendly
 *   name; defaults to the generic `dal_*` ABI ({@link DAL_SYMBOLS})
 * @param {string[]} [o.targets] supported target keys for the error hint
 * @returns {{ lib: Record<string,any>, koffi: any, callAsync: Function,
 *   decodeResult: (ptr:any)=>FfiReader, version: string,
 *   nativeDir: ()=>string, defaultCacheRoot: ()=>string }}
 */
export function loadNative({
  here,
  packageName,
  coreName = DEFAULT_CORE_NAME,
  symbols = DAL_SYMBOLS,
  targets,
}) {
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

  const CORE = coreFile(coreName);
  let lib;
  function loadLib() {
    if (lib) return lib;
    const koffi = koffiModule();
    const dir = nativeDir();
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
