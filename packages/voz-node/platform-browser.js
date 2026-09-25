// Browser half of the `#platform` seam, resolved through the "browser" import
// condition so the node-only code in platform-node.js never enters the browser
// module graph.
import { installAudioHost } from "@desert-ant-labs/core/audio";

/** The bundle, keyed by revision, so a new pin does not read the old cache. */
const CACHE_NAME = "desert-ant-voz";

export async function setupCore() {
  const { init } = await import("./dist/index.js");
  const { exports } = await init({ getImports: () => imports });
  return { exports };
}

/**
 * The shared model-host import, which Voz never calls.
 *
 * Voz's core does not use the single-session `dalModelHost` seam (it drives
 * three graphs through its own `__vozHost`), but it reaches that module through
 * DesertAnt, and the generated instantiator asks for the import unconditionally.
 * Throwing rather than no-op'ing: if one of these is ever reached, the wiring is
 * wrong and a silent success would hide it.
 */
const imports = {
  dalModelHost: {
    createSessionFromPath: unreachable,
    createSessionFromBytes: unreachable,
    run: unreachable,
    findModel: unreachable,
    loadModelFromPath: unreachable,
    loadModelFromBytes: unreachable,
    runModel: unreachable,
  },
};

async function unreachable() {
  throw new Error("voz: the shared model host is not part of this model's path");
}

/** onnxruntime-web finds its own .wasm files next to its bundle by default, so
 *  nothing to point at. A consumer self-hosting them passes `wasmDir`. */
export async function defaultOrtWasmDir() {
  return undefined;
}

/**
 * The browser's ONNX Runtime, imported on demand the way the LiteRT models
 * import theirs, so `Voz.load()` needs nothing passed and a page that never
 * transcribes never downloads it: bundlers split a dynamic import into its own
 * chunk.
 *
 * `/webgpu` rather than `/all`: that entry is ONNX Runtime's native WebGPU
 * execution provider, where the 4-bit MatMulNBits kernels live, and it carries
 * WebNN too. `/all` is the older JSEP path, whose kernels are TypeScript.
 *
 * Measured on this encoder, one batch of six windows on an M5, per window:
 * JSEP runs float16 at 82 ms and 4-bit at 379; the native EP runs float16 at 92
 * and 4-bit at 89. The native EP is the only one where a quantized encoder is
 * not a penalty, which is what takes the resident weights from 1.19 GB to
 * 349 MB and the browser's word error rate level with Core ML.
 *
 * How much that costs depends on the chip. Ten minutes of audio on WebGPU
 * alone, quantized against float16: an M5 runs 125 against 122 and an M3 Ultra
 * 255 against 250, but an M1 runs 37.9 against 43.3, because the 4-bit kernels
 * want subgroup-matrix instructions an M1 does not have.
 *
 * This import puts one `node:os` reference in a consumer's bundle, inside
 * onnxruntime-web's own thread-count code:
 *
 *     typeof navigator > "u" ? nodeRequire(node:os).cpus().length : navigator.hardwareConcurrency
 *
 * (written without quotes here on purpose: the bundle matrix greps output for a
 * quoted builtin, and a scenario that does not minify would see this comment)
 *
 * It is a guarded call in a branch a browser never takes, not a static import,
 * so it neither breaks a build nor runs. The bundle matrix knows the difference
 * (see `assertBrowserClean`): a static import of a node builtin still fails
 * everywhere, and a guarded one is allowed only in a chunk that carries the
 * runtime itself.
 */
export async function defaultRuntime(packageName) {
  try {
    return await import("onnxruntime-web/webgpu");
  } catch (cause) {
    const missing = cause?.code === "ERR_MODULE_NOT_FOUND"
      || cause?.code === "MODULE_NOT_FOUND"
      || String(cause?.message ?? "").includes("onnxruntime-web");
    if (!missing) throw cause;
    throw new Error(
      `${packageName} needs onnxruntime-web in the browser. `
        + `Install it with: npm i ${packageName} onnxruntime-web. `
        + "If you bundle a runtime yourself, pass it to load({ ort }).",
      { cause },
    );
  }
}

/**
 * Read bundle files through the Cache API, so a reload is a cache hit rather
 * than 395 MB over the network again.
 *
 * Not IndexedDB or OPFS: these are immutable HTTP resources, which is what the
 * Cache API is for, and it is the one browser store the runtime can serve a
 * response from without a copy through JS.
 */
export async function makeFetchFile({ revision, cache, onProgress }) {
  const store = cache && typeof caches !== "undefined"
    ? await caches.open(`${CACHE_NAME}-${revision}`).catch(() => null)
    : null;
  let done = 0;
  const names = new Set();

  return async (url, name) => {
    names.add(name);
    let response = store ? await store.match(url) : undefined;
    let bytes;
    if (response) {
      bytes = new Uint8Array(await response.arrayBuffer());
    } else {
      response = await fetch(url);
      if (!response.ok) throw new Error(`voz: ${name} -> HTTP ${response.status}`);
      // Read first, then cache what was read. `response.clone()` reads cleaner
      // but buffers the body a second time to feed both readers, which on a
      // 349 MB file is 349 MB of peak for nothing. A quota failure is not
      // fatal, only slower next time.
      bytes = new Uint8Array(await response.arrayBuffer());
      if (store) await store.put(url, new Response(bytes)).catch(() => {});
    }
    done += 1;
    onProgress?.(done / Math.max(names.size, 1));
    return bytes;
  };
}

/**
 * WebGPU where the adapter can compile this encoder, the CPU where it cannot.
 *
 * The shaders need `shader-f16`. A machine with no GPU still exposes a software
 * adapter, and that one lacks it: the session fails to compile rather than
 * running slowly, so this has to be asked before loading rather than caught
 * afterwards.
 */
export async function bestProvider() {
  const adapter = await navigator.gpu?.requestAdapter().catch(() => null);
  return adapter?.features?.has("shader-f16") ? "webgpu" : "wasm";
}

/** A Blob for anything the browser hands over that is already one. Files and
 *  Blobs are read lazily from disk, which is what lets a long recording stream
 *  rather than be held. */
export async function asBlob(input) {
  return typeof Blob !== "undefined" && input instanceof Blob ? input : null;
}

/** What a relative `modelBaseUrl` is relative to: the page, including a <base>
 *  tag if the app sets one. */
export function pageUrl() {
  return typeof document !== "undefined" ? document.baseURI : location.href;
}

/**
 * Web Audio decodes any container the browser supports and renders it to mono
 * at the rate we ask for.
 *
 * Then it is checked against what the container says it holds, because
 * `decodeAudioData` can return a short buffer and no error: a 29-minute file
 * came back as 54.7 seconds, and the only sign of it was a transcript that
 * stopped early with everything reporting success. Reading the duration from a
 * media element is a second opinion from the same browser, and a cheap one:
 * it parses the metadata without decoding.
 *
 * Silent truncation is worse than a failure here. A caller who gets an error
 * converts the file; a caller who gets 3% of their audio may never notice.
 *
 * A video file is the case this cannot be strict about: its audio track is
 * allowed to be shorter than the movie (a recording whose microphone stopped
 * early is a real file, not a broken one), and the container duration is the
 * longest track. So a mismatch there is a warning and a mismatch in an
 * audio-only file, where the two durations are the same thing, is an error.
 */
export async function decodeAudio(bytes, sampleRate) {
  const samples = await installAudioHost().decode(null, bytes, sampleRate);
  const { seconds: declared, video } = await containerMetadata(bytes);
  const decoded = samples.length / sampleRate;
  // 2% and a second of slack: a container's duration is rounded, and an
  // encoder's padding is real audio that the decoder may drop.
  if (declared && decoded < declared * 0.98 - 1) {
    const detail = `decoded ${decoded.toFixed(1)}s of a ${declared.toFixed(1)}s file`;
    if (video) {
      console.warn(
        `voz: ${detail}. In a video that is normal when the audio track is shorter `
        + "than the picture; if it is not, the browser's decoder truncated it and "
        + "converting the file to WAV will tell you which.");
    } else {
      throw new Error(
        `voz: this browser ${detail}. That is the browser's decoder, not the model. `
        + "Convert the file to WAV, or decode it yourself and pass the samples.");
    }
  }
  return samples;
}

/**
 * What the container claims, from a media element: its duration in seconds and
 * whether it carries a picture. Metadata only, so no decode, and the element is
 * never attached to the page.
 *
 * A `<video>` rather than an `Audio()`, because it reports both, and reports
 * audio-only files with `videoWidth === 0`.
 */
async function containerMetadata(bytes) {
  const empty = { seconds: null, video: false };
  if (typeof document === "undefined" || typeof URL?.createObjectURL !== "function") return empty;
  const url = URL.createObjectURL(new Blob([bytes]));
  try {
    return await new Promise((resolve) => {
      const element = document.createElement("video");
      element.preload = "metadata";
      const done = (value) => { element.src = ""; resolve(value); };
      element.addEventListener("loadedmetadata", () => {
        done({
          seconds: Number.isFinite(element.duration) && element.duration > 0
            ? element.duration : null,
          video: element.videoWidth > 0,
        });
      });
      element.addEventListener("error", () => done(empty));
      // A container the element cannot parse is not a reason to fail a decode
      // that worked, so give up rather than hang.
      setTimeout(() => done(empty), 5000);
      element.src = url;
    });
  } finally {
    URL.revokeObjectURL(url);
  }
}
