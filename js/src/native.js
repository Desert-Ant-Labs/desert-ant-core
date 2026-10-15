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
import { createPublicKey, verify } from "node:crypto";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { FfiReader } from "./ffi.js";
import { makeCallGroups } from "./callgroup.js";

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

// The Linux core opens the system libcurl itself (Tools/curlcompat) rather
// than linking it, so a host without one still loads the library and would
// only fail at the first download or license request, as an abort. Asked right
// after the core loads, before any other call, so it is an ordinary error from
// load() instead. A core built before the probe existed has no such symbol;
// its dlopen already failed on a missing libcurl, so there is nothing to check.
// Exported for the unit test, which hands it a fake core; node.js does not
// re-export it.
export function checkLibcurl(core, packageName, platform = process.platform) {
  if (platform !== "linux") return;
  let available;
  try {
    available = core.func("int dal_curl_available()");
  } catch {
    return;
  }
  if (available()) return;
  throw new Error(
    `${packageName}: libcurl is required (downloads and licensing) but ` +
      `libcurl.so.4 could not be loaded. Install libcurl4 (Debian, Ubuntu) or ` +
      `libcurl (Fedora, Amazon Linux).`,
  );
}

export function verifyLicenseSignature(signature, message, publicKey) {
  if (signature.length !== 64 || publicKey.length !== 65 || publicKey[0] !== 4) return false;
  const coordinate = (start) => Buffer.from(publicKey.subarray(start, start + 32)).toString("base64url");
  try {
    const key = createPublicKey({
      key: { kty: "EC", crv: "P-256", x: coordinate(1), y: coordinate(33) },
      format: "jwk",
    });
    return verify("sha256", message, { key, dsaEncoding: "ieee-p1363" }, signature);
  } catch {
    return false;
  }
}

export function licenseVerifyCallback(koffi) {
  const bytes = (pointer, length) =>
    length > 0 ? Uint8Array.from(koffi.decode(pointer, koffi.array("uint8", length))) : new Uint8Array();
  return (signature, signatureLength, message, messageLength, publicKey, publicKeyLength) =>
    verifyLicenseSignature(
      bytes(signature, signatureLength),
      bytes(message, messageLength),
      bytes(publicKey, publicKeyLength),
    )
      ? 1
      : 0;
}

// Before 2.16.3 (3.1.2 on 3.x), a koffi callback from a core thread can crash Node, or hang or crash it at exit.
export function koffiCallbacksAreSafe(version) {
  const [major, minor, patch] = String(version).split(".").map(Number);
  const since = (m, n, p) => major === m && (minor > n || (minor === n && patch >= p));
  return major > 3 || since(3, 1, 2) || since(2, 16, 3);
}

// The Linux core has no crypto of its own, so it checks license signatures through Node.
export function installLicenseVerifier(core, koffi, platform = process.platform) {
  if (platform !== "linux" || !koffiCallbacksAreSafe(koffi.version)) return;
  const verifier = koffi.pointer(
    koffi.proto("int", ["const uint8_t *", "int", "const uint8_t *", "int", "const uint8_t *", "int"]),
  );
  let install;
  try {
    install = core.func("dal_set_license_verifier", "int", [verifier]);
  } catch {
    return;
  }
  install(koffi.register(licenseVerifyCallback(koffi), verifier));
  // A core thread's call waits for this event loop, so the loop stays up until none is in flight.
  process.on("beforeExit", () => {
    if (install(null) > 0) setTimeout(() => {}, 10);
  });
}

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
  // The `flushTelemetry()` behind the SDKs': block until the license requests
  // in flight finish.
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
          `Use the Swift package or a browser build where this model has one.`,
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
    checkLibcurl(core, packageName);
    installLicenseVerifier(core, koffi);
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
  // caller frees the pointer (via `dal_buffer_free`).
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

  // The managed cache layout (<cacheRoot>/desert-ant-models/<repo>/<revision>)
  // is owned by desert-ant-core's Swift ModelStore, so there is no JS-side
  // model-path computation.

  const { withCallGroup } = makeCallGroups();

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
