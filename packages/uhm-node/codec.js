// Uhm's FFI payload schemas: what a run takes and what it returns.
//
// Both cores (the native `dal_run` and the WebAssembly `run`) speak the same
// payloads, so they live here once.
// Mirrors the reader/writer in Sources/Uhm/Binding.swift.
import { FfiWriter } from "@desert-ant-labs/core";

/** The catalog id: how both cores are asked for Uhm, and the key its
 *  WebAssembly exports are registered under. */
export const MODEL_ID = "uhm";

export const PACKAGE_NAME = "@desert-ant-labs/uhm";

/** The rate the model works at. Audio at any other rate is resampled. */
export const SAMPLE_RATE = 16_000;

/** The confidence each bias preset gates at. The presets live in Swift
 *  (`Uhm.Bias`); what crosses the boundary is the number. */
export const BIAS = Object.freeze({
  precision: 0.75,
  balanced: 0.65,
  recall: 0.5,
});

/** Input payload: `f32Array samples` (mono), `f64 sampleRate`, then, when
 *  `words` is given, `u32 count` and `f64 start, f64 end, string text` each. */
export function encodeInput(samples, sampleRate, words) {
  const w = new FfiWriter().f32Array(samples).f64(sampleRate);
  if (words) {
    w.u32(words.length);
    for (const word of words) w.f64(word.start).f64(word.end).str(word.text);
  }
  return w.done();
}

/** Options payload: `f64 minConfidence` (NaN for the balanced preset), `f64
 *  minDurationSec` (NaN for the default), `u32 includeTypes`, then `f64
 *  minOverlapFraction` (NaN for 0.5) and `u32 splitContainedWords`. Empty means
 *  every default. */
export function encodeOptions(options = {}) {
  const { bias, minConfidence, minDurationSec, includeTypes, reconcile } = options;
  const explicit = [bias, minConfidence, minDurationSec, includeTypes, reconcile]
    .some((v) => v !== undefined);
  if (!explicit) return new Uint8Array(0);
  if (bias !== undefined && !Object.hasOwn(BIAS, bias)) throw new Error(`${PACKAGE_NAME}: unknown bias "${bias}"`);
  const threshold = minConfidence ?? (bias === undefined ? NaN : BIAS[bias]);
  return new FfiWriter()
    .f64(threshold)
    .f64(minDurationSec ?? NaN)
    .u32(includeTypes === false ? 0 : 1)
    .f64(reconcile?.minOverlapFraction ?? NaN)
    .u32(reconcile?.splitContainedWords ? 1 : 0)
    .done();
}

/** Result payload: `f64 audioDuration`, `u32 count`, then per filler `f64
 *  start, f64 end, f64 confidence, string type` (empty when the type labeler did
 *  not run, which is every platform but Apple), then, only when words were
 *  sent, `u32 count` and `f64 start, f64 end, string text` per reconciled word.
 *  `r` is the reader the core hands back, already positioned. */
export function decodeResult(r) {
  const audioDuration = r.f64();
  const count = r.u32();
  const fillers = [];
  for (let i = 0; i < count; i++) {
    const start = r.f64();
    const end = r.f64();
    const confidence = r.f64();
    const type = r.str();
    fillers.push({ start, end, confidence, type: type === "" ? null : type });
  }
  let words = null;
  if (r.remaining >= 4) {
    const n = r.u32();
    words = [];
    for (let i = 0; i < n; i++) {
      const start = r.f64();
      const end = r.f64();
      words.push({ start, end, text: r.str() });
    }
  }
  return { audioDuration, fillers, words };
}
