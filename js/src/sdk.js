// The shared model-SDK runtime: one implementation of "load a model, run it,
// dispose it" for both cores a Desert Ant package ships.
//
// The two cores now expose the same surface - the WebAssembly ABI BridgeJS
// generates from Swift's `@JS` entry points and the native `dal_*` C ABI bound
// with koffi - so the
// only difference between a package's browser entry and its native entry is
// which core it binds and, for the browser, the LiteRT.js session it has to set
// up first. Everything after that (create or adopt, download with progress,
// encode options, run, decode, group calls, dispose) is identical for every
// model on every runtime, so it lives here once.
//
// A model package is then: its payload codecs, its public class over
// `LoadedModel`, and two lines of wiring per entry point.
import { makeCallGroups } from "./callgroup.js";
import { FfiReader } from "./ffi.js";
import {
  assertBrowserRuntime,
  fetchSelfHostedModel,
  installLiteRtHost,
  loadLiteRt,
} from "./litert.js";

/**
 * A loaded model behind an opaque core handle: the object a package's public
 * class delegates to. `core` is a normalized core (see `wasmCore` /
 * `createNativeSdk`), so this class never knows which runtime it is on.
 */
export class LoadedModel {
  #core;
  #packageName;
  #handle;

  constructor({ core, packageName, handle }) {
    this.#core = core;
    this.#packageName = packageName;
    this.#handle = handle;
  }

  /**
   * Run the model over `text` with the model's own options payload, returning an
   * `FfiReader` over its result payload for the caller's decoder.
   *
   * @param {string} text
   * @param {Uint8Array} options the model's encoded options
   * @param {{ group?: string, deviceId?: string | (() => string) }} [call]
   */
  async run(text, options, call = {}) {
    if (this.#handle == null) throw new Error(`${this.#packageName}: model disposed`);
    const group = call.group != null ? String(call.group) : null;
    const deviceId = typeof call.deviceId === "function" ? call.deviceId() : call.deviceId;
    return this.#core.run(
      this.#handle, text, options, group, deviceId != null ? String(deviceId) : null);
  }

  /** Whether the model is usable with no network. */
  isDownloaded() {
    return this.#handle != null && this.#core.isDownloaded(this.#handle);
  }

  /**
   * Run `body(group)` with a fresh call-group id, so every call inside that
   * passes `{ group }` bills as a single usage call. Released when `body`
   * settles.
   */
  withCallGroup(body) {
    return this.#core.withCallGroup(body);
  }

  /** Release the model. Calls afterwards throw. */
  dispose() {
    if (this.#handle == null) return;
    this.#core.destroy(this.#handle);
    this.#handle = null;
  }
}

/**
 * Turn a fresh handle into a ready `LoadedModel`: download and load the model
 * now (a no-op when it is already available), so the first call is instant and
 * `load()` surfaces a download failure instead of the first inference doing so.
 */
export async function readyModel({ core, packageName, handle, onProgress }) {
  if (!handle) throw new Error(`${packageName}: failed to create the model`);
  const model = new LoadedModel({ core, packageName, handle });
  try {
    await core.download(handle, onProgress);
  } catch (cause) {
    model.dispose();
    throw new Error(`${packageName}: model download failed: ${cause}`, { cause });
  }
  onProgress?.(1);
  return model;
}

/**
 * Normalize the WebAssembly ABI (the module's BridgeJS exports) to the core shape
 * `LoadedModel` uses: a run that yields an `FfiReader`, plus the call-group
 * helper.
 *
 * `download` always passes a progress function: BridgeJS does not accept an
 * optional closure parameter, so "no callback" is a no-op rather than `null`.
 */
export function wasmCore(exports) {
  return {
    create: (cacheRoot, directory) => exports.create(cacheRoot ?? null, directory ?? null),
    createSelfHosted: (files) => exports.createSelfHosted(files),
    isDownloaded: (handle) => exports.isDownloaded(handle),
    download: (handle, onProgress) => exports.download(handle, onProgress ?? (() => {})),
    run: async (handle, text, options, group, deviceId) =>
      new FfiReader(
        await exports.run(handle, text, options ?? null, group ?? null, deviceId ?? null)),
    destroy: (handle) => exports.destroy(handle),
    flushTelemetry: () => exports.flushTelemetry(),
    ...makeCallGroups((id) => exports.endCallGroup(id)),
  };
}

/**
 * The browser/WebAssembly half of a model package: instantiate the core through
 * the package's `#platform` seam, then hand back an `open(options)` that
 * resolves the model and returns a ready `LoadedModel`.
 *
 * Both load paths live here because neither is model-specific: the default
 * downloads this platform's files from the Hub (verified and cached by the Swift
 * core), and `modelBaseUrl` fetches files the app serves itself, compiles the
 * model in LiteRT.js, and passes only the sidecars into wasm - the browser's
 * equivalent of pointing a native SDK at a directory that already holds the
 * model.
 *
 * @param {object} o
 * @param {any} o.platform the package's `#platform` module
 * @param {string} o.packageName consumer package (for error messages)
 * @param {string} o.hostGlobal e.g. "__EmoHost"
 * @param {{ model: string, sidecars: string[] }} o.files names under a
 *   `modelBaseUrl`, as in the model catalog
 */
export async function createWasmSdk({ platform, packageName, hostGlobal, files }) {
  // The core instantiates at import time (the package's entry top-level awaits
  // this); the model is only wired in open().
  const core = wasmCore(await platform.setupCore());

  // Debug-only hook for forcing the usage POST out and awaiting it (the browser
  // example and the browser suite do this before asserting). The core's exports
  // belong to this module instance rather than a global registry, so this is how
  // a page reaches them; it exists only under the same flag the telemetry log
  // itself needs.
  if (globalThis.__dalHttpDebug) {
    globalThis.__dalFlushTelemetry = () => core.flushTelemetry();
  }

  return {
    core,
    async open(options = {}) {
      assertBrowserRuntime({ packageName, litert: options.litert });
      const lrt = await loadLiteRt({
        litert: options.litert,
        wasmDir: options.litertWasmDir,
        defaultWasmDir: platform.defaultWasmDir,
        packageName,
      });
      const accelerator = options.accelerator ?? "wasm";
      // Generic tensor I/O with the wasm core (JSInferenceSession): the core
      // installs the host and manages tensor memory; setModel lets the
      // modelBaseUrl branch feed the same run() closure.
      const { setModel } = installLiteRtHost({
        hostGlobal,
        accelerator,
        loadAndCompile: lrt.loadAndCompile,
        Tensor: lrt.Tensor,
        readModelSource: platform.readModelSource,
      });

      const onProgress = typeof options.onProgress === "function" ? options.onProgress : undefined;
      let handle;
      if (options.modelBaseUrl != null) {
        const { sidecars, modelBytes } = await fetchSelfHostedModel(options.modelBaseUrl, files);
        setModel(await lrt.loadAndCompile(modelBytes, { accelerator }));
        handle = core.createSelfHosted(sidecars);
      } else {
        // `directory` (node) adopts a folder you populated. Base for the managed
        // nested cache (node): ~/.cache; empty (in-memory) in the browser.
        const cacheRoot = options.cacheRoot ?? (await platform.defaultCacheRoot());
        handle = core.create(cacheRoot, options.directory ?? null);
      }
      return readyModel({ core, packageName, handle, onProgress });
    },
  };
}
