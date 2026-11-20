// The shared model-SDK runtime: one implementation of "load a model, run it,
// dispose it" for both cores a Desert Ant package ships.
//
// The two cores expose the same surface (the WebAssembly ABI BridgeJS generates
// from Swift's `@JS` entry points, and the native `dal_*` C ABI bound with
// koffi), so the only difference between a package's browser entry and its native entry is
// which core it binds and, for the browser, the LiteRT.js session it has to set
// up first. Everything after that (create or adopt, download with progress,
// encode options, run, decode, dispose) is identical for every model on every
// runtime, so it lives here once.
//
// A model package is then: its payload codecs, its public class over
// `LoadedModel`, and two lines of wiring per entry point.
import { makeCallGroups } from "./callgroup.js";
import { hostLogLevel, registerLogInstaller } from "./log.js";
import { FfiReader } from "./ffi.js";
import {
  assertBrowserRuntime,
  fetchSelfHostedModel,
  compileModel,
  makeLiteRtHost,
  loadLiteRt,
  handleNamespace,
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

  #onDispose;
  // Calls started and not yet settled, and whether `dispose()` was called: the handle and its models outlive
  // `dispose()` until the calls already in flight finish.
  #pending = 0;
  #disposed = false;

  constructor({ core, packageName, handle, onDispose }) {
    this.#core = core;
    this.#packageName = packageName;
    this.#handle = handle;
    this.#onDispose = onDispose;
  }

  /**
   * Run the model over its own input payload with its own options payload,
   * returning an `FfiReader` over its result payload for the caller's decoder.
   *
   * Both payloads are the model's: text, audio samples, video frames - the shape
   * is the model's codec's business and nothing about it reaches this layer.
   *
   * @param {Uint8Array} input the model's encoded input
   * @param {Uint8Array} options the model's encoded options
   * @param {{ group?: string, deviceId?: string | (() => string) }} [call] `group` has no effect
   */
  async run(input, options, call = {}) {
    if (this.#disposed || this.#handle == null) throw new Error(`${this.#packageName}: model disposed`);
    const deviceId = typeof call.deviceId === "function" ? call.deviceId() : call.deviceId;
    this.#pending += 1;
    try {
      return await this.#core.run(
        this.#handle, input, options, null, deviceId != null ? String(deviceId) : null);
    } finally {
      this.#pending -= 1;
      if (this.#disposed && this.#pending === 0) this.#release();
    }
  }

  /** Whether the model is usable with no network. */
  isDownloaded() {
    return !this.#disposed && this.#handle != null && this.#core.isDownloaded(this.#handle);
  }

  /** @deprecated Has no effect: runs `body` with a group id that nothing reads. */
  withCallGroup(body) {
    return this.#core.withCallGroup(body);
  }

  /**
   * Wait for the license requests in flight, so a process that ends right
   * after loading a model does not exit before they finish.
   */
  flushTelemetry() {
    // Every core built from this source binds the hook; this covers one that does
    // not, e.g. a host supplying its own binary.
    return this.#core.flushTelemetry?.() ?? Promise.resolve(true);
  }

  /** Release the model. Calls afterwards throw; calls already started finish first. */
  dispose() {
    if (this.#disposed) return;
    this.#disposed = true;
    if (this.#pending === 0) this.#release();
  }

  #release() {
    if (this.#handle == null) return;
    this.#core.destroy(this.#handle);
    this.#handle = null;
    this.#onDispose?.();
  }
}

/**
 * Turn a fresh handle into a ready `LoadedModel`: download and load the model
 * now (a no-op when it is already available), so the first call is instant and
 * `load()` surfaces a download failure instead of the first inference doing so.
 */
export async function readyModel({ core, packageName, handle, onProgress, onDispose }) {
  if (!handle) {
    onDispose?.();
    throw new Error(`${packageName}: failed to create the model`);
  }
  const model = new LoadedModel({ core, packageName, handle, onDispose });
  try {
    await core.download(handle, onProgress);
  } catch (cause) {
    model.dispose();
    throw new Error(`${packageName}: model download failed: ${cause}`, { cause });
  }
  onProgress?.(1);
  return model;
}

/** `modelBaseUrl` as an absolute URL ending in `/`: the namespace of the models a self-hosted load compiles. */
function selfHostedNamespace(baseUrl) {
  const base = baseUrl.endsWith("/") ? baseUrl : `${baseUrl}/`;
  try {
    return new URL(base, globalThis.location?.href).href;
  } catch {
    return base;
  }
}

/**
 * Normalize the WebAssembly ABI (the module's BridgeJS exports) to the core shape
 * `LoadedModel` uses: a run that yields an `FfiReader`.
 *
 * `download` always passes a progress function: BridgeJS does not accept an
 * optional closure parameter, so "no callback" is a no-op rather than `null`.
 */
export function wasmCore(exports) {
  return {
    create: (cacheRoot, directory, variant) => variant
      ? exports.createVariant(variant, cacheRoot ?? null, directory ?? null)
      : exports.create(cacheRoot ?? null, directory ?? null),
    createSelfHosted: (files, variant) => variant
      ? exports.createSelfHostedVariant(variant, files)
      : exports.createSelfHosted(files),
    isDownloaded: (handle) => exports.isDownloaded(handle),
    download: (handle, onProgress) => exports.download(handle, onProgress ?? (() => {})),
    run: async (handle, input, options, group, deviceId) =>
      new FfiReader(
        await exports.run(handle, input, options ?? null, group ?? null, deviceId ?? null)),
    destroy: (handle) => exports.destroy(handle),
    flushTelemetry: () => exports.flushTelemetry(),
    ...makeCallGroups(),
  };
}

// The level a host set (see log.js), applied to the core now and again whenever
// DesertAnt.logLevel changes. A core built before the export existed reads the
// global itself at its first message, and a later change does not reach it.
function installLogLevel(exports) {
  if (typeof exports.setLogLevel !== "function") return;
  const apply = () => {
    const level = hostLogLevel();
    if (level !== null) exports.setLogLevel(level);
  };
  apply();
  registerLogInstaller(apply);
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
 * What a `modelBaseUrl` must serve is not passed in: the core reports it through
 * `modelInfo()`, generated from the model's Swift catalog declaration, so a model
 * package restates none of it.
 *
 * @param {object} o
 * @param {any} o.platform the package's `#platform` module
 * @param {string} o.packageName consumer package (for error messages)
 * @param {string} [o.defaultAccelerator] when load options name none: "wasm", or "auto" (WebGPU when available)
 */
export async function createWasmSdk({ platform, packageName, defaultAccelerator = "wasm" }) {
  // The core instantiates at import time (the package's entry top-level awaits
  // this); the model is only wired in open().
  const { exports, installHost } = await platform.setupCore();
  const core = wasmCore(exports);
  const { artifact, sidecars } = exports.modelInfo();
  let liteRtHost;
  // Numbers the self-hosted loads: each names its models apart from every other's.
  let selfHostedLoads = 0;
  installLogLevel(exports);

  // Debug-only hook for awaiting the license requests in flight. The core's
  // exports belong to this module instance rather than a global registry, so
  // this is how a page reaches them; it exists only under the HTTP debug flag.
  if (globalThis.__dalHttpDebug) {
    globalThis.__dalFlushTelemetry = () => core.flushTelemetry();
  }

  return {
    core,
    /**
     * `variant` is another way to run the model (Face's `"detector"`, Eye's
     * `"faceprints"`); `files` is what that variant's `modelBaseUrl` serves, when
     * it is not the model's own `{ artifact, sidecars }`.
     */
    open: (options = {}, how = {}) => openOne(options, how),
  };

  async function openOne(options, { variant, files }) {
    assertBrowserRuntime({ packageName, litert: options.litert });
    const lrt = await loadLiteRt({
      litert: options.litert,
      wasmDir: options.litertWasmDir,
      defaultWasmDir: platform.defaultWasmDir,
      packageName,
    });
    const accelerator = options.accelerator ?? defaultAccelerator;
    // Generic tensor I/O with the wasm core (JSInferenceSession): the host
    // owns the LiteRT sessions and tensor memory, and `setModel` lets the
    // modelBaseUrl branch feed the same run() implementation. One host per
    // core, installed by the first open: every instance of the module runs
    // through it, each under its own prefix (see `makeLiteRtHost`), compiled
    // for the accelerator its own open asked for.
    liteRtHost ??= makeLiteRtHost({
      accelerator,
      loadAndCompile: lrt.loadAndCompile,
      Tensor: lrt.Tensor,
      readModelSource: platform.readModelSource,
    });
    const { host, setModel, scope, release } = liteRtHost;
    installHost(host);
    // The prefixes this instance's models are named under, freed when it is disposed.
    const prefixes = [];
    const own = (prefix) => {
      prefixes.push(prefix);
      scope(prefix, accelerator);
    };
    let released = false;
    const releaseAll = () => {
      if (!released) for (const prefix of prefixes) release(prefix);
      released = true;
    };

    try {
      const onProgress = typeof options.onProgress === "function" ? options.onProgress : undefined;
      let handle;
      if (options.modelBaseUrl != null) {
        const served = files ?? { artifact, sidecars };
        const { sidecars: fetched, modelBytes } =
          await fetchSelfHostedModel(options.modelBaseUrl, { model: served.artifact, sidecars: served.sidecars });
        // Named after this load and where its files came from.
        const namespace = `s${++selfHostedLoads}/${selfHostedNamespace(options.modelBaseUrl)}`;
        own(namespace);
        const compiled = await compileModel(lrt.loadAndCompile, modelBytes, accelerator);
        setModel(compiled.model, compiled.accelerator, namespace);
        // A model sidecar (Eye's face detector) is compiled here under its file
        // name, like the artifact; the rest cross into wasm.
        for (const name of Object.keys(fetched).filter((n) => n.endsWith(".tflite"))) {
          const other = await compileModel(lrt.loadAndCompile, fetched[name], accelerator);
          setModel(other.model, other.accelerator, namespace + name);
          delete fetched[name];
        }
        fetched[".dal-namespace"] = new TextEncoder().encode(namespace);
        handle = core.createSelfHosted(fetched, variant);
      } else {
        // `directory` (node) adopts a folder you populated. Base for the managed
        // nested cache (node): ~/.cache; empty (in-memory) in the browser.
        const cacheRoot = options.cacheRoot ?? (await platform.defaultCacheRoot());
        handle = core.create(cacheRoot, options.directory ?? null, variant);
      }
      // What the core compiles for this instance itself, on download or first use.
      if (handle) own(handleNamespace(handle));
      return await readyModel({ core, packageName, handle, onProgress, onDispose: releaseAll });
    } catch (error) {
      releaseAll();
      throw error;
    }
  }
}
