// The shared server-side native loader for the model node packages: it resolves
// the per-host prebuilt Swift core under native/<platform>-<arch>, loads the
// LiteRT runtime first (so the core's DT_NEEDED resolves in-process), binds the
// model's C ABI with koffi, and runs blocking calls on a libuv worker thread.
//
// Node-only (uses node:*, koffi). Browser code never imports this file.
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { FfiReader } from "./ffi.js";

const require = createRequire(import.meta.url);

// koffi is loaded lazily (only when a native library is actually loaded), so
// loadNative()/nativeDir() work in environments without the optional koffi peer.
let _koffi;
function koffiModule() {
  return (_koffi ??= require("koffi"));
}

// The LiteRT runtime is the same across models; the core library name is the
// model's (e.g. "ShapesNode" -> libShapesNode.so / .dylib / ShapesNode.dll).
const RUNTIME = { linux: "libLiteRt.so", darwin: "libLiteRt.dylib", win32: "LiteRt.dll" };
const coreFile = (name) => ({ linux: `lib${name}.so`, darwin: `lib${name}.dylib`, win32: `${name}.dll` });

/**
 * Load and bind the prebuilt native core for this host.
 *
 * @param {object} o
 * @param {string} o.here directory of the model's node.js (import.meta dir)
 * @param {string} o.packageName consumer package (for error messages)
 * @param {string} o.coreName C core base name, e.g. "ShapesNode"
 * @param {Record<string,string>} o.symbols koffi prototypes keyed by a friendly
 *   name, e.g. { create: "void* shapes_create(const char*, const char*)", ... }
 * @param {string[]} [o.targets] supported target keys for the error hint
 * @returns {{ lib: Record<string,any>, koffi: any, callAsync: Function,
 *   decodeResult: (ptr:any)=>FfiReader, version: string,
 *   nativeDir: ()=>string, defaultCacheRoot: ()=>string }}
 */
export function loadNative({ here, packageName, coreName, symbols, targets }) {
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

  return {
    get koffi() {
      return koffiModule();
    },
    lib: new Proxy({}, { get: (_t, prop) => loadLib()[prop] }),
    callAsync,
    decodeResult,
    version,
    nativeDir,
    defaultCacheRoot,
  };
}
