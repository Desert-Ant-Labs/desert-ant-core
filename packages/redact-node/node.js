// On-device multilingual PII redaction for JavaScript, server-side (Node). This
// is the `node` conditional-exports entry: it runs the same Redact pipeline as
// the browser build, but natively via the prebuilt Swift core (LiteRT under the
// hood) instead of WebAssembly + LiteRT.js. Consumers just `import { Redact }` —
// Node resolves this file, browsers resolve `browser.js`. No flags, no setup.
//
// The koffi harness (resolve native/<platform>-<arch>, load the LiteRT runtime
// first, bind the generic `dal_*` C ABI, run blocking calls off the event loop)
// and the FFI codecs live in @desert-ant-labs/core/node; this file supplies only
// Redact's public API; the payload schemas it shares with the browser entry
// live in codec.js.
import { fileURLToPath } from "node:url";
import path from "node:path";
import { loadNative } from "@desert-ant-labs/core/node";
import { MODEL_ID, PACKAGE_NAME, encodeOptions, decodeRedaction } from "./codec.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));

// The prebuilt native for this host lives in native/<platform>-<arch>/ next to
// this file (built by `mise run node-natives`): the self-contained Swift core
// (libDesertAntNode, one library for every model) plus the LiteRT runtime it
// links (libLiteRt). The symbol table is the shared `dal_*` ABI, so it is the
// loader's default and this call names no symbols.
const core = loadNative({ here: HERE, packageName: PACKAGE_NAME });
const { lib, callAsync, decodeResult, withCallGroup } = core;

/**
 * On-device multilingual PII redaction. Create one with `await Redact.load(...)`
 * and reuse it, mirroring the browser SDK and the iOS/Swift SDK.
 *
 * ```js
 * const redact = await Redact.load();                 // downloads the model on demand, cached
 * const r = await redact.redaction("Email Anna at anna@example.com.");
 * r.redactedText; r.items; r.restore(reply);
 * redact.dispose();                                   // free the native handle when done
 * ```
 */
export class Redact {
  #handle;
  constructor(handle) { this.#handle = handle; }

  /**
   * Load the model and return a ready redactor. Download, SHA-256 verification,
   * and caching are handled by the native core; the repo and revision are
   * pinned to the SDK.
   */
  static async load(options = {}) {
    // Managed nested cache under ~/.cache by default (matches the browser host);
    // an explicit `directory` is adopted if it holds the files, else downloaded.
    const cacheRoot = options.cacheRoot ?? core.defaultCacheRoot();
    const directory = options.directory ?? null;
    const handle = lib.create(MODEL_ID, cacheRoot, directory);
    if (!handle) throw new Error(`${PACKAGE_NAME}: failed to create redactor`);
    const redact = new Redact(handle);
    // Ready the model now so the first redaction is instant and load() surfaces
    // any download error, matching the browser's eager `load()`.
    const onProgress = typeof options.onProgress === "function" ? options.onProgress : undefined;
    if (lib.isDownloaded(handle) === 0) {
      onProgress?.(0);
      const rc = await callAsync(lib.download, handle);
      if (rc !== 0) { redact.dispose(); throw new Error(`${PACKAGE_NAME}: model download failed`); }
    }
    onProgress?.(1);
    return redact;
  }

  /**
   * Detect and redact the PII in `text`. Each entity is replaced by a unique,
   * numbered placeholder (`[EMAIL_1]`, ...), safe to hand to an LLM and restore
   * afterwards via `Redaction.restore`.
   *
   * Usage is tracked automatically. By default each call is its own billed usage
   * call. Pass `options.group` (an id from {@link withCallGroup}) to bill several
   * calls as one, and `options.deviceId` (a string, or a zero-arg function
   * returning one) to attribute usage to a specific end-user device on
   * multi-tenant hosts.
   */
  async redaction(text, options = {}) {
    if (!this.#handle) throw new Error(`${PACKAGE_NAME}: redactor disposed`);
    const minimumConfidence = options.minimumConfidence ?? 0.6;
    const deviceId = typeof options.deviceId === "function" ? options.deviceId() : options.deviceId;
    const group = options.group != null ? String(options.group) : null;
    const payload = encodeOptions({
      minimumConfidence,
      labels: options.labels ? Array.from(options.labels) : undefined,
    });
    const ptr = await callAsync(
      lib.run, this.#handle, String(text ?? ""), payload, payload.length, group,
      deviceId != null ? String(deviceId) : null);
    if (!ptr) throw new Error(`${PACKAGE_NAME}: redaction failed`);
    try {
      return decodeRedaction(decodeResult(ptr));
    } finally {
      lib.bufferFree(ptr);
    }
  }

  /**
   * Run `body` with a call group, so every `redaction({ group })` inside it bills
   * as a single usage call rather than one per redaction. The group is released
   * when `body` settles.
   */
  withCallGroup(body) {
    return withCallGroup(body);
  }

  /** Free the native handle. Call when you are done with the redactor. */
  dispose() {
    if (this.#handle) { lib.destroy(this.#handle); this.#handle = null; }
  }
}
