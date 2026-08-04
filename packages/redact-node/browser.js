// On-device multilingual PII redaction for JavaScript. This is the universal
// entry: it resolves model assets, owns the LiteRT.js session (via
// @desert-ant-labs/core), and exposes the public typed API (a `Redact` class
// with an async `load` factory). It runs in the browser and, via the platform
// seam below, server-side in Node (the Client-Component SSR pass frameworks
// render in Node), both on the same WebAssembly + @litertjs/core (LiteRT.js)
// pipeline: XNNPACK-accelerated CPU ("wasm") by default, with optional WebGPU in
// the browser.
//
// All node-only code lives behind the `#platform` import, which bundlers resolve
// at build time by condition (browser -> platform-browser.js, otherwise
// platform-node.js). That keeps this file free of `node:*` and of any static
// reference to node-only chunks, so a single import builds cleanly for every
// target of a multi-target bundler. For a prebuilt native server core (no
// @litertjs/core, best server throughput), import `@desert-ant-labs/redact/native`.
import { setupCore, defaultWasmDir, readModelSource, defaultCacheRoot } from "#platform";
import { installLiteRtHost, loadLiteRt, assertBrowserRuntime } from "@desert-ant-labs/core";

const PACKAGE_NAME = "@desert-ant-labs/redact";

// The wasm core instantiates at import time (top-level await); the model is
// only wired in load(). The build-time-selected platform seam owns whatever is
// node- or browser-specific about instantiation.
const core = await setupCore();

/**
 * On-device multilingual PII redaction. Create one with `await Redact.load(...)`
 * and reuse it, mirroring the iOS/Swift SDK.
 *
 * ```js
 * const redact = await Redact.load();               // download on demand, cached
 * const r = await redact.redaction("Email Anna at anna@example.com.");
 * r.redactedText; r.items; r.restore(reply);
 * ```
 */
export class Redact {
  /**
   * Load the model and return a ready redactor. By default the runtime downloads
   * the model from the Hugging Face Hub at the SDK's pinned tag (fetched +
   * cached by the browser) and @desert-ant-labs/core owns the LiteRT.js session
   * behind the generic tensor contract (createSession + run). Pass `modelBaseUrl`
   * (a base URL you serve the files from) to self-host / run without the Hub.
   * The repo and revision are pinned to the SDK.
   */
  static async load(options = {}) {
    const resolved = options;
    assertBrowserRuntime({ packageName: PACKAGE_NAME, litert: resolved.litert });
    const lrt = await loadLiteRt({
      litert: resolved.litert,
      wasmDir: resolved.litertWasmDir,
      defaultWasmDir,
      packageName: PACKAGE_NAME,
    });
    const { loadAndCompile, Tensor } = lrt;
    const accelerator = resolved.accelerator ?? "wasm";

    // Generic tensor I/O with the WebAssembly runtime (JSInferenceSession): the
    // redact tflite takes int32 input_ids + attention_mask and returns the token
    // logits. @desert-ant-labs/core installs the host + manages tensor memory;
    // setModel lets the modelBaseUrl branch feed the same run() closure.
    const { setModel } = installLiteRtHost({
      hostGlobal: "__RedactHost",
      accelerator,
      loadAndCompile,
      Tensor,
      readModelSource,
    });

    const onProgress = typeof resolved.onProgress === "function" ? resolved.onProgress : undefined;
    if (resolved.modelBaseUrl != null) {
      // Self-hosted files (offline / no runtime CDN): fetch the model + sidecars
      // from the given base URL, compile the model here, and hand the labels +
      // tokenizer to the wasm core, no Hub download. This is the browser opt-out,
      // e.g. an app that serves the model from its own origin.
      const { labelsJSON, tokenizerBytes, modelBytes } = await fetchModelFrom(resolved.modelBaseUrl);
      setModel(await loadAndCompile(modelBytes, { accelerator }));
      await core.loadBundled(labelsJSON, tokenizerBytes);
      onProgress?.(1);
    } else {
      // Default: the runtime downloads this platform's files from the HF Hub at
      // the pinned tag (SHA-256 verified), fetched + cached by the JS host, and
      // wires the session through the installed host. `directory` (node) adopts
      // a self-hosted folder. Base for the managed nested cache (node): ~/.cache;
      // empty (in-memory) in the browser.
      const cacheRoot = await defaultCacheRoot();
      await core.load(cacheRoot, resolved.directory ?? "", onProgress);
    }
    return new Redact();
  }

  /**
   * Detect and redact the PII in `text`. Each entity is replaced by a unique,
   * numbered placeholder (`[EMAIL_1]`, ...), safe to hand to an LLM and restore
   * afterwards via the returned `restore`.
   */
  async redaction(text, options = {}) {
    const raw = await core.redaction(
      text, options.minimumConfidence ?? 0.6,
      options.labels ? Array.from(options.labels) : undefined);
    const items = Array.from(raw.items).map((i) => ({ ...i }));
    return {
      redactedText: raw.redactedText,
      items,
      restore(processed) {
        let out = processed;
        for (const item of items) out = out.replaceAll(item.placeholder, item.original);
        return out;
      },
    };
  }

  /**
   * Free native resources. No-op in the WebAssembly runtime; present so the same
   * code works against the native server build (`@desert-ant-labs/redact/native`).
   */
  dispose() {}
}

// Fetch self-hosted model files from a base URL (the `modelBaseUrl` opt-out).
// Accepts absolute URLs and root-relative paths (e.g. "/assets/redact/").
async function fetchModelFrom(baseUrl) {
  const base = baseUrl.endsWith("/") ? baseUrl : `${baseUrl}/`;
  const [labels, tokenizer, model] = await Promise.all([
    fetch(`${base}labels.json`).then((r) => r.text()),
    fetch(`${base}redact_tokenizer.bin`).then((r) => r.arrayBuffer()),
    fetch(`${base}redact.tflite`).then((r) => r.arrayBuffer()),
  ]);
  return {
    labelsJSON: labels,
    tokenizerBytes: new Uint8Array(tokenizer),
    modelBytes: new Uint8Array(model),
  };
}
