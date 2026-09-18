// Voz's public JavaScript API, shared by every entry point.
//
// The core is the same `Pipeline` the Swift SDK runs, compiled to WebAssembly:
// windowing, the boundary search, the lane-batched decode and the splice. What
// this file adds is the part a browser owns - fetching the bundle, compiling
// three graphs, choosing an execution provider - and the audio conversions a
// caller should not have to do by hand.
//
// `platform` is the `#platform` seam: instantiating the core, caching bundle
// files, and decoding audio all differ between a browser and Node, and nothing
// else here does.
import { loadVoz, hasWebNN } from "@desert-ant-labs/core";
import { hubBaseUrl, PACKAGE_NAME, SAMPLE_RATE } from "./codec.js";
import { mediaSource, wavSource } from "./stream.js";

/** Resample with linear interpolation, which is what the frontend's own
 *  portable path uses. Only reached when a caller's rate is not 16 kHz. */
function resample(samples, from, to) {
  if (from === to) return samples;
  const ratio = from / to;
  const out = new Float32Array(Math.max(1, Math.round(samples.length / ratio)));
  for (let i = 0; i < out.length; i++) {
    const at = i * ratio;
    const low = Math.floor(at);
    const high = Math.min(low + 1, samples.length - 1);
    out[i] = samples[low] + (samples[high] - samples[low]) * (at - low);
  }
  return out;
}

export function makeVoz(platform) {
  /**
   * An on-device recogniser. One instance holds three compiled graphs and about
   * 1.2 GB of resident weights, so load it once and reuse it; a transcription
   * holds the instance for its whole run and concurrent calls queue.
   */
  return class Voz {
    #core;
    #host;

    constructor(core, host) {
      this.#core = core;
      this.#host = host;
    }

    /**
     * Fetch the bundle, compile it, and load the core.
     *
     * In a browser nothing is required: install onnxruntime-web alongside this
     * package and the platform seam imports it on demand, the same way the
     * LiteRT models get their runtime.
     *
     *     const voz = await Voz.load();
     *
     * Under Node you pass it, because the runtime there is a native addon and
     * a package that imports one cannot be bundled for a server:
     *
     *     import * as ort from "onnxruntime-node";
     *     const voz = await Voz.load({ ort });
     *
     * @param {object} [o]
     * @param {any} [o.ort] an ONNX Runtime module, instead of the default
     * @param {string} [o.modelBaseUrl] serve the bundle yourself; ends in "/"
     * @param {string} [o.revision] a different Hub revision of the bundle
     * @param {boolean} [o.webnn] override the WebNN detection
     * @param {string} [o.wasmDir] where onnxruntime-web's own .wasm files live
     * @param {(fraction: number) => void} [o.onProgress] download progress
     * @param {boolean} [o.cache] cache the downloaded bundle (default true)
     * @param {"auto"|"webgpu"|"wasm"} [o.ep] where the graphs run. "auto"
     *   (default) takes WebGPU when the adapter can compile this encoder's f16
     *   shaders and the CPU when it cannot, which is what a machine with no GPU
     *   looks like: it exposes a software adapter that fails to compile rather
     *   than running slowly, so there is no fallback to discover at run time.
     */
    static async load({
      ort: supplied, modelBaseUrl, revision, webnn = hasWebNN(), wasmDir,
      onProgress, cache = true, ep = "auto",
    } = {}) {
      const core = await platform.setupCore();
      const info = core.exports.modelInfo();
      const asked = modelBaseUrl ?? hubBaseUrl(info, revision ?? info.revision);
      if (!asked.endsWith("/")) {
        throw new Error(`voz: modelBaseUrl must end in "/", got ${asked}`);
      }
      // Resolved against the page, because serving the bundle from your own
      // origin means writing a path ("/models/voz/"), and every file fetch
      // below goes through `new URL(name, baseUrl)`, which rejects a relative
      // base.
      const baseUrl = /^[a-z][a-z0-9+.-]*:/i.test(asked)
        ? asked
        : new URL(asked, platform.pageUrl()).toString();

      const loaded = await loadVoz({
        baseUrl,
        ort: supplied ?? (await platform.defaultRuntime(PACKAGE_NAME)),
        ep: ep === "auto" ? await platform.bestProvider() : ep,
        wasmDir: wasmDir ?? (await platform.defaultOrtWasmDir()),
        webnn,
        // 390 MB over the wire and 1.19 GB expanded: a reload that re-downloads
        // it is not something a consumer should have to build themselves.
        fetchFile: await platform.makeFetchFile({
          info, revision: revision ?? info.revision, cache, onProgress,
        }),
      });

      const meta = loaded.meta;
      await core.exports.load(
        loaded.metaBytes, loaded.vocab, loaded.embedding,
        meta.decode_lanes, meta.encode_batch, meta.fused_frontend === true,
      );
      return new Voz(core, loaded.host);
    }

    /**
     * Transcribe audio, returning the text and a word list with times.
     *
     * Takes whatever a caller has: mono 16 kHz `Float32Array` samples (no
     * conversion), `{ samples, sampleRate }` at any rate, or the bytes of an
     * encoded file (`ArrayBuffer`, `Uint8Array`, `Blob`, `File`), which the
     * browser decodes with Web Audio and Node with the portable WAV codec.
     *
     * @returns {Promise<{ text: string, words: Array<{ text: string, start: number, end: number }>,
     *   duration: number, processingTime: number, realtimeFactor: number }>}
     */
    async transcribe(input, { onProgress, sampleRate } = {}) {
      this.#host.resetTimings();

      // Anything file-shaped is read in pieces, so memory does not grow with
      // its length: the core asks for the next chunk when it needs one and
      // frees what is behind the window it is transcribing. WAV is framed
      // simply enough to slice directly; every other container is demuxed and
      // decoded by mediabunny, also a chunk at a time.
      const blob = await platform.asBlob(input);
      if (blob) {
        const streamed = (await wavSource(blob)) ?? (await mediaSource(blob));
        if (streamed) {
          const result = await this.#core.exports.transcribeStream(
            streamed.seconds, streamed.totalSamples,
            (count) => streamed.pull(count),
            onProgress ?? (() => {}));
          return this.#finish(result);
        }
      }

      const samples = await this.#samples(input, sampleRate);
      if (!samples.length) throw new Error("voz: no samples to transcribe");
      const result = await this.#core.exports.transcribe(
        samples, onProgress ?? (() => {}));
      return this.#finish(result);
    }

    /// Seconds of audio per second of wall clock, as the Swift result reports
    /// it, so a caller does not divide two fields to get the number everything
    /// else in this project quotes.
    #finish(result) {
      return {
        ...result,
        realtimeFactor: result.processingTime > 0
          ? result.duration / result.processingTime : 0,
      };
    }

    /** Per-model call counts and wall time for the last transcription. Useful
     *  for attributing a slow run to the encoder or the decode step. */
    get timings() {
      return this.#host.timings;
    }

    /** Coerce whatever the caller passed into mono 16 kHz samples. */
    async #samples(input, sampleRate) {
      if (input instanceof Float32Array) {
        return resample(input, sampleRate ?? SAMPLE_RATE, SAMPLE_RATE);
      }
      if (input && ArrayBuffer.isView(input) && !(input instanceof Uint8Array)) {
        throw new Error("voz: pass Float32Array samples, or the bytes of an audio file");
      }
      if (input && typeof input === "object" && "samples" in input) {
        return resample(
          input.samples instanceof Float32Array ? input.samples : new Float32Array(input.samples),
          input.sampleRate ?? sampleRate ?? SAMPLE_RATE, SAMPLE_RATE);
      }
      const bytes = await toBytes(input);
      if (!bytes) {
        throw new Error("voz: expected Float32Array samples, { samples, sampleRate }, " +
          "or the bytes of an audio file");
      }
      // Already mono at the model's rate: the decoders downmix and resample.
      return platform.decodeAudio(bytes, SAMPLE_RATE);
    }
  };
}

async function toBytes(input) {
  if (input instanceof Uint8Array) return input;
  if (input instanceof ArrayBuffer) return new Uint8Array(input);
  if (typeof Blob !== "undefined" && input instanceof Blob) {
    return new Uint8Array(await input.arrayBuffer());
  }
  return null;
}
