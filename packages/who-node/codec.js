// Who's FFI payload schemas: the audio a run takes, the options beside it, and
// the diarization it returns. Both cores speak the same payloads (the native
// `dal_run` in node.js and the WebAssembly `run` in browser.js), so they live
// here once. Mirrors Sources/Who/Binding.swift.
import { FfiWriter } from "@desert-ant-labs/core";
import { Diarization, Turn } from "./diarization.js";

/** The catalog id: how both cores are asked for Who. */
export const MODEL_ID = "who";

export const PACKAGE_NAME = "@desert-ant-labs/who";

/** The model's sample rate. Samples at another rate are resampled by the core. */
export const SAMPLE_RATE = 16000;

/**
 * Normalize what a caller passed into `{ samples, sampleRate }`: mono
 * `Float32Array` samples (at 16 kHz unless `sampleRate` says otherwise),
 * `{ samples, sampleRate }` at any rate, or the bytes of an audio file
 * (`ArrayBuffer`, `Uint8Array`, `Blob`, `File`), which `decodeAudio` renders to
 * mono at the model's rate.
 */
export async function toAudio(input, sampleRate, decodeAudio) {
  if (input instanceof Float32Array) {
    return { samples: input, sampleRate: sampleRate ?? SAMPLE_RATE };
  }
  if (input && typeof input === "object" && "samples" in input) {
    const samples = input.samples instanceof Float32Array ? input.samples : Float32Array.from(input.samples);
    return { samples, sampleRate: input.sampleRate ?? sampleRate ?? SAMPLE_RATE };
  }
  const bytes = await toBytes(input);
  if (!bytes) {
    throw new TypeError("pass Float32Array samples, { samples, sampleRate }, or the bytes of an audio file");
  }
  return { samples: await decodeAudio(bytes, SAMPLE_RATE), sampleRate: SAMPLE_RATE };
}

async function toBytes(input) {
  if (input instanceof Uint8Array) return input;
  if (input instanceof ArrayBuffer) return new Uint8Array(input);
  if (typeof Blob !== "undefined" && input instanceof Blob) return new Uint8Array(await input.arrayBuffer());
  return null;
}

/** Input payload: `f32[] samples` (mono), then `f64 sampleRate`. */
export function encodeInput({ samples, sampleRate }) {
  if (!(samples instanceof Float32Array) || samples.length === 0) throw new TypeError("no samples to diarize");
  if (!(sampleRate > 0)) throw new TypeError("sampleRate must be positive");
  return new FfiWriter().f32Array(samples).f64(sampleRate).done();
}

/** Options payload: empty, every option at its default. */
export function encodeOptions() {
  return new FfiWriter().done();
}

/**
 * Result payload: `u32 speakerCount`, then `u32 count` and that many
 * `(u32 speaker, f64 start, f64 end)` by start time, then `f64 duration`.
 */
export function decodeDiarization(r) {
  const speakerCount = r.u32();
  const turns = [];
  for (let n = r.u32(); n > 0; n--) {
    const speaker = r.u32();
    turns.push(new Turn(speaker, r.f64(), r.f64()));
  }
  return new Diarization(turns, r.f64(), speakerCount);
}
