// On-device emoji suggestion for JavaScript. This is the universal entry: it
// resolves model assets, owns the LiteRT.js session (via @desert-ant-labs/core),
// and exposes the public typed API (an `Emo` class with an async `load`
// factory). It runs in the browser and, via the platform seam below,
// server-side in Node (the Client-Component SSR pass frameworks render in Node),
// both on the same WebAssembly + @litertjs/core (LiteRT.js) pipeline:
// XNNPACK-accelerated CPU ("wasm") by default, with optional WebGPU in the
// browser.
//
// The WebAssembly core exposes the same model-agnostic ABI as the native core
// (create / download / run / destroy, with options and results as FFI payloads),
// so this file and node.js share `codec.js` and differ only in which core they
// drive.
//
// All node-only code lives behind the `#platform` import, which bundlers resolve
// at build time by condition (browser -> platform-browser.js, otherwise
// platform-node.js). That keeps this file free of `node:*` and of any static
// reference to node-only chunks, so a single import builds cleanly for every
// target of a multi-target bundler. For a prebuilt native server core (no
// @litertjs/core, best server throughput), import `@desert-ant-labs/emo/native`.
import { setupCore, defaultWasmDir, readModelSource, defaultCacheRoot } from "#platform";
import { installLiteRtHost, loadLiteRt, assertBrowserRuntime, FfiReader } from "@desert-ant-labs/core";
import {
  PACKAGE_NAME, HOST_GLOBAL, MODEL_FILES, SKIN_TONES, encodeOptions, decodeSuggestions,
} from "./codec.js";

// The wasm core instantiates at import time (top-level await); the model is
// only wired in load(). The build-time-selected platform seam owns whatever is
// node- or browser-specific about instantiation.
const core = await setupCore();

/**
 * On-device emoji suggestion. Create one with `await Emo.load(...)` and reuse
 * it, mirroring the iOS/Swift SDK.
 *
 * ```js
 * const emo = await Emo.load();                 // downloads the model on first use, cached
 * const suggestions = await emo.suggestions("Pay my bills");  // [{ emoji, confidence }, ...]
 * ```
 */
export class Emo {
  #handle;
  constructor(handle) { this.#handle = handle; }

  /**
   * Load the model and return a ready suggester. By default the model is
   * downloaded from the Hugging Face Hub at the pinned revision, verified, and
   * cached by the runtime (Cache API / IndexedDB in the browser);
   * @desert-ant-labs/core owns the LiteRT.js session behind the generic tensor
   * contract (createSession + run). Pass a `modelBaseUrl` to fetch self-hosted
   * files from your own origin (offline / no runtime CDN) instead. The repo and
   * revision are pinned to the SDK.
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
    // emo tflite takes the n-gram/semantic int32/float32 inputs and returns a
    // float32 `probabilities` tensor. @desert-ant-labs/core installs the host +
    // manages tensor memory; setModel lets the modelBaseUrl branch feed the same
    // run() closure.
    const { setModel } = installLiteRtHost({
      hostGlobal: HOST_GLOBAL,
      accelerator,
      loadAndCompile,
      Tensor,
      readModelSource,
    });

    const onProgress = typeof resolved.onProgress === "function" ? resolved.onProgress : undefined;
    let handle;
    if (resolved.modelBaseUrl != null) {
      // Self-hosted files (offline / no runtime CDN): fetch the model + sidecars
      // from the given base URL, compile the model here, and hand the sidecars
      // to the wasm core, no Hub download. This is the browser's equivalent of
      // pointing the native SDKs at a directory that already holds the model:
      // nothing is bundled, nothing is downloaded.
      const { sidecars, modelBytes } = await fetchModelFrom(resolved.modelBaseUrl);
      setModel(await loadAndCompile(modelBytes, { accelerator }));
      handle = core.createSelfHosted(sidecars);
    } else {
      // Default: the core downloads this platform's files from the HF Hub at the
      // pinned tag (SHA-256 verified), fetched + cached by the JS host, and
      // wires the session through the installed host. `directory` (node) adopts
      // a folder you populated. Base for the managed nested cache (node):
      // ~/.cache; empty (in-memory) in the browser.
      handle = core.create(await defaultCacheRoot(), resolved.directory ?? "");
    }
    if (!handle) throw new Error(`${PACKAGE_NAME}: failed to create suggester`);
    const emo = new Emo(handle);
    // Ready the model now (downloading if needed) so the first suggestion is
    // instant and load() surfaces any download error, as the native build does.
    try {
      await core.download(handle, onProgress);
    } catch (cause) {
      emo.dispose();
      throw new Error(`${PACKAGE_NAME}: ${cause}`, { cause });
    }
    onProgress?.(1);
    return emo;
  }

  /**
   * Suggest emojis for a phrase, most likely first. Returns up to `limit`
   * `{ emoji, confidence }` suggestions; empty input returns `[]`.
   *
   * `options.deviceId` (a string or a zero-arg function returning one)
   * attributes usage to a specific end-user device. It is collected per call
   * and bound to that call, so it is safe for concurrent multi-tenant hosts.
   * `options.group` (an id from {@link withCallGroup}) bills several calls as
   * one.
   */
  async suggestions(text, options = {}) {
    if (!this.#handle) throw new Error(`${PACKAGE_NAME}: suggester disposed`);
    const phrase = String(text ?? "");
    if (phrase.trim() === "") return [];
    const payload = encodeOptions({
      limit: options.limit ?? 3,
      skinTone: SKIN_TONES[options.skinTone ?? "default"] ?? 0,
    });
    const group = options.group != null ? String(options.group) : null;
    const result = await core.run(this.#handle, phrase, payload, group, options.deviceId ?? null);
    return decodeSuggestions(new FfiReader(result));
  }

  /**
   * Run `body` with a call group, so every `suggestions({ group })` inside it
   * bills as a single usage call rather than one per suggestion. The group is
   * released when `body` settles.
   */
  async withCallGroup(body) {
    const id = `emo-${Math.random().toString(36).slice(2)}-${Date.now()}`;
    try {
      return await body(id);
    } finally {
      core.endCallGroup(id);
    }
  }

  /** Release the model. The suggester is unusable afterwards. */
  dispose() {
    if (this.#handle) { core.destroy(this.#handle); this.#handle = null; }
  }
}

// Fetch self-hosted model files from a base URL (the `modelBaseUrl` opt-out).
// Accepts absolute URLs and root-relative paths (e.g. "/assets/emo/"). The
// sidecars go to the wasm core keyed by their catalog names; the model bytes
// stay here and are compiled by LiteRT.js.
async function fetchModelFrom(baseUrl) {
  const base = baseUrl.endsWith("/") ? baseUrl : `${baseUrl}/`;
  const [meta, tokenizer, model] = await Promise.all([
    fetch(`${base}${MODEL_FILES.meta}`).then((r) => r.text()),
    fetch(`${base}${MODEL_FILES.tokenizer}`).then((r) => r.arrayBuffer()),
    fetch(`${base}${MODEL_FILES.model}`).then((r) => r.arrayBuffer()),
  ]);
  return {
    sidecars: {
      [MODEL_FILES.meta]: meta,
      [MODEL_FILES.tokenizer]: new Uint8Array(tokenizer),
    },
    modelBytes: new Uint8Array(model),
  };
}
