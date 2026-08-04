// On-device multilingual PII redaction for JavaScript, server-side (Node). This
// is the `node` conditional-exports entry: it runs the same Redact pipeline as
// the browser build, but natively via the prebuilt Swift core (LiteRT under the
// hood) instead of WebAssembly + LiteRT.js. Consumers just `import { Redact }` —
// Node resolves this file, browsers resolve `browser.js`. No flags, no setup.
//
// The koffi harness (resolve native/<platform>-<arch>, load the LiteRT runtime
// first, bind the C ABI, run blocking calls off the event loop) and the FFI
// buffer decode live in @desert-ant-labs/core/node; this file supplies the C
// ABI, the model decode, and the public API.
import { fileURLToPath } from "node:url";
import path from "node:path";
import { loadNative } from "@desert-ant-labs/core/node";

const HERE = path.dirname(fileURLToPath(import.meta.url));

// The prebuilt native for this host lives in native/<platform>-<arch>/ next to
// this file (built by `mise run node-natives`): the self-contained Swift core
// (libRedactNode) plus the LiteRT runtime it links (libLiteRt).
const core = loadNative({
  here: HERE,
  packageName: "@desert-ant-labs/redact",
  coreName: "RedactNode",
  symbols: {
    create: "void* redact_create(const char*, const char*)",
    isDownloaded: "int redact_is_downloaded(void*)",
    download: "int redact_download(void*)",
    run: "void* redact_run(void*, const char*, double, const char*)",
    destroy: "void redact_destroy(void*)",
    stringFree: "void redact_string_free(void*)",
  },
});
const { lib, callAsync, decodeResult } = core;

/** Decode the FFI buffer the core returns: the redacted text, then a u32 count
 *  and per item label/original/placeholder (strings), an f64 confidence, and
 *  u32 start/end offsets, read off the shared FfiReader. Mirrors
 *  `encodeRedaction` in Sources/RedactAndroid/CABI.swift. */
function decodeRedaction(r) {
  const redactedText = r.str();
  const count = r.u32();
  const items = [];
  for (let i = 0; i < count; i++) {
    const label = r.str();
    const original = r.str();
    const placeholder = r.str();
    const confidence = r.f64();
    const start = r.u32();
    const end = r.u32();
    items.push({ label, original, placeholder, confidence, start, end });
  }
  return { redactedText, items };
}

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
    const handle = lib.create(cacheRoot, directory);
    if (!handle) throw new Error("@desert-ant-labs/redact: failed to create redactor");
    const redact = new Redact(handle);
    // Ready the model now so the first redaction is instant and load() surfaces
    // any download error, matching the browser's eager `load()`.
    const onProgress = typeof options.onProgress === "function" ? options.onProgress : undefined;
    if (lib.isDownloaded(handle) === 0) {
      onProgress?.(0);
      const rc = await callAsync(lib.download, handle);
      if (rc !== 0) { redact.dispose(); throw new Error("@desert-ant-labs/redact: model download failed"); }
    }
    onProgress?.(1);
    return redact;
  }

  /**
   * Detect and redact the PII in `text`. Each entity is replaced by a unique,
   * numbered placeholder (`[EMAIL_1]`, ...), safe to hand to an LLM and restore
   * afterwards via `Redaction.restore`.
   */
  async redaction(text, options = {}) {
    if (!this.#handle) throw new Error("@desert-ant-labs/redact: redactor disposed");
    const minimumConfidence = options.minimumConfidence ?? 0.6;
    const labelsCSV = options.labels ? Array.from(options.labels).join(",") : null;
    const ptr = await callAsync(lib.run, this.#handle, text, minimumConfidence, labelsCSV);
    if (!ptr) throw new Error("@desert-ant-labs/redact: redaction failed");
    try {
      const raw = decodeRedaction(decodeResult(ptr));
      const items = raw.items.map((i) => ({ ...i }));
      return {
        redactedText: raw.redactedText,
        items,
        restore(processed) {
          let out = processed;
          for (const item of items) out = out.replaceAll(item.placeholder, item.original);
          return out;
        },
      };
    } finally {
      lib.stringFree(ptr);
    }
  }

  /** Free the native handle. Call when you are done with the redactor. */
  dispose() {
    if (this.#handle) { lib.destroy(this.#handle); this.#handle = null; }
  }
}
