// On-device multilingual emoji suggestion for JavaScript, server-side (Node).
// This is the `node` conditional-exports entry: it runs the same Emo pipeline as
// the browser build, but natively via the prebuilt Swift core (LiteRT under the
// hood) instead of WebAssembly + LiteRT.js. Consumers just `import { Emo }` —
// Node resolves this file, browsers resolve `browser.js`. No flags, no setup.
//
// The koffi harness (resolve native/<platform>-<arch>, load the LiteRT runtime
// first, bind the generic `dal_*` C ABI, run blocking calls off the event loop)
// and the FFI codecs live in @desert-ant-labs/core/node; this file supplies only
// Emo's public API; the payload schemas it shares with the browser entry live
// in codec.js.
import { fileURLToPath } from "node:url";
import path from "node:path";
import { loadNative } from "@desert-ant-labs/core/node";
import { MODEL_ID, PACKAGE_NAME, SKIN_TONES, encodeOptions, decodeSuggestions } from "./codec.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));

// The prebuilt native for this host lives in native/<platform>-<arch>/ next to
// this file (built by `mise run node-natives`): the self-contained Swift core
// (libDesertAntNode, one library for every model) plus the LiteRT runtime it
// links (libLiteRt). The symbol table is the shared `dal_*` ABI, so it is the
// loader's default and this call names no symbols.
const core = loadNative({ here: HERE, packageName: PACKAGE_NAME });
const { lib, callAsync, decodeResult, withCallGroup } = core;

/**
 * On-device multilingual emoji suggestion. Create one with `await Emo.load(...)`
 * and reuse it, mirroring the browser SDK and the iOS/Swift SDK.
 *
 * ```js
 * const emo = await Emo.load();                        // downloads the model on first use, cached
 * const suggestions = await emo.suggestions("Pay my bills");  // [{ emoji, confidence }, ...]
 * emo.dispose();                                       // free the native handle when done
 * ```
 */
export class Emo {
  #handle;
  constructor(handle) { this.#handle = handle; }

  /**
   * Load the model and return a ready suggester. By default the model is
   * downloaded from the Hugging Face Hub at the pinned revision, SHA-256
   * verified, and cached under the OS cache dir by the native core; the repo
   * and revision are pinned to the SDK. Pass a `directory` to adopt self-hosted
   * files (offline) instead of downloading.
   *
   * The server-side native runs LiteRT on Linux (from the `.tflite`) and Core ML
   * on macOS (from the compiled `.mlmodelc` directory); the core downloads only
   * this host's artifact and loads it by path - one primitive, both runtimes.
   */
  static async load(options = {}) {
    const onProgress = typeof options.onProgress === "function" ? options.onProgress : undefined;
    // Directory is null by default: the native core (built without the bundled-
    // model trait) downloads into the single managed cache layout that
    // desert-ant-core owns - <cacheRoot>/desert-ant-models/<repo>/<revision> -
    // shared by every Desert Ant SDK and by the browser/wasm path. An explicit
    // `directory` adopts a consumer-provided folder for offline use.
    const cacheRoot = options.cacheRoot ?? core.defaultCacheRoot();
    const directory = options.directory ?? null;
    const handle = lib.create(MODEL_ID, cacheRoot, directory);
    if (!handle) throw new Error(`${PACKAGE_NAME}: failed to create suggester`);
    const emo = new Emo(handle);
    // Ready the model now (download if needed) so the first suggestion is instant
    // and load() surfaces any download error.
    if (lib.isDownloaded(handle) === 0) {
      onProgress?.(0);
      const rc = await callAsync(lib.download, handle);
      if (rc !== 0) { emo.dispose(); throw new Error(`${PACKAGE_NAME}: model download failed`); }
    }
    onProgress?.(1);
    return emo;
  }

  /**
   * Suggest emojis for `text`, most likely first. Returns up to `limit`
   * `{ emoji, confidence }` suggestions; empty input returns `[]`.
   *
   * Usage is tracked automatically. By default each call is its own billed
   * usage call. Pass `options.group` (an id from {@link withCallGroup}) to bill
   * several calls as one — a logical operation made of multiple suggestions.
   *
   * Pass `options.deviceId` (a string, or a zero-arg function returning one) to
   * attribute usage to a specific end-user device on multi-tenant hosts. It is
   * collected per call and bound to that call, so it is safe under concurrency.
   * Omit to attribute to the host device.
   */
  async suggestions(text, options = {}) {
    if (!this.#handle) throw new Error(`${PACKAGE_NAME}: suggester disposed`);
    const phrase = String(text ?? "");
    if (phrase.trim() === "") return [];
    const limit = options.limit ?? 3;
    const skinTone = SKIN_TONES[options.skinTone ?? "default"] ?? 0;
    const deviceId = typeof options.deviceId === "function" ? options.deviceId() : options.deviceId;
    const group = options.group != null ? String(options.group) : null;
    const payload = encodeOptions({ limit, skinTone });
    const ptr = await callAsync(
      lib.run, this.#handle, phrase, payload, payload.length, group,
      deviceId != null ? String(deviceId) : null);
    if (!ptr) throw new Error(`${PACKAGE_NAME}: suggestion failed`);
    try {
      return decodeSuggestions(decodeResult(ptr));
    } finally {
      lib.bufferFree(ptr);
    }
  }

  /**
   * Run `body` with a call group, so every `suggestions({ group })` inside it
   * bills as a single usage call (rather than one per suggestion). Use it for a
   * logical operation that issues several suggestions but should count once:
   *
   * ```js
   * await emo.withCallGroup(async (group) => {
   *   await emo.suggestions("a", { group });
   *   await emo.suggestions("b", { group });  // same group -> counted as one call
   * });
   * ```
   *
   * The group is released when `body` settles.
   */
  withCallGroup(body) {
    return withCallGroup(body);
  }

  /** Free the native handle. Call when you are done with the suggester. */
  dispose() {
    if (this.#handle) { lib.destroy(this.#handle); this.#handle = null; }
  }
}
