// Ear's FFI payload schemas: what a run takes and what it returns.
//
// Both cores (the native `dal_run` and the WebAssembly `run`) speak the same
// payloads, so they live here once.
// Mirrors the reader/writer in Sources/Ear/Binding.swift.
import { FfiWriter } from "@desert-ant-labs/core";

/** The catalog id: how both cores are asked for Ear, and the key its
 *  WebAssembly exports are registered under. */
export const MODEL_ID = "ear";

export const PACKAGE_NAME = "@desert-ant-labs/ear";

/** The rate the model works at. Audio at any other rate is resampled. */
export const SAMPLE_RATE = 16_000;

/** Input payload: `f32Array` samples (mono), then `f64 sampleRate`. */
export function encodeInput(samples, sampleRate) {
  return new FfiWriter().f32Array(samples).f64(sampleRate).done();
}

/** Options payload: `f64 windows`. Empty means the SDK default of three. */
export function encodeOptions({ windows } = {}) {
  if (windows === undefined || windows === null) return new Uint8Array(0);
  return new FfiWriter().f64(windows).done();
}

/** Result payload: `u32 count`, then that many `(string, f64)` pairs
 *  most-likely first, then `f64 windows` and `f64 reliable`.
 *
 *  Takes the reader the core hands back, not raw bytes: both cores return one
 *  already positioned, and a second reader over the same buffer would misread it. */
export function decodeResult(r) {
  const count = r.u32();
  const candidates = [];
  for (let i = 0; i < count; i++) {
    candidates.push({ language: r.str(), probability: r.f64() });
  }
  const windows = r.f64();
  // `reliable` is decided in Swift rather than recomputed here; see
  // Sources/Ear/Binding.swift.
  const isReliable = r.f64() === 1;
  const top = candidates[0];
  return {
    language: top ? top.language : null,
    confidence: top ? top.probability : 0,
    candidates,
    windows,
    isReliable,
  };
}
