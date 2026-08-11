// Clear's FFI payload schemas: the options a run takes and the result it
// returns.
//
// These are the only model-specific part of talking to the core, and both cores
// speak the same payloads - the native `dal_run` (node.js) and the WebAssembly
// `run` (browser.js) - so they live here once instead of in each entry point.
// Mirrors the reader/writer in Sources/Clear/Binding.swift.
import { FfiWriter } from "@desert-ant-labs/core";

/** The catalog id: how both cores are asked for Clear, and the key its
 *  WebAssembly exports are registered under. */
export const MODEL_ID = "clear";

export const PACKAGE_NAME = "@desert-ant-labs/clear";

/** Integrated-LUFS targets for the platforms Clear ships presets for. The
 *  presets themselves live in Swift (`Clear.LoudnessPreset`); what crosses the
 *  boundary is the number, so adding one here breaks no core. */
export const LOUDNESS_PRESETS = Object.freeze({
  applePodcasts: -19,
  podcast: -19,
  spotify: -14,
  youtube: -14,
  broadcast: -23,
});

/** Input payload: `f32Array samples` (mono), then `f64 sampleRate`. */
export function encodeInput(samples, sampleRate) {
  return new FfiWriter().f32Array(samples).f64(sampleRate).done();
}

/** Options payload: `f64 strength`, then the mastering chain as
 *  `f64 integratedLUFS` (NaN bypasses mastering), `f64 truePeakDBTP`,
 *  `f64 maxLoudnessGainDB`. */
export function encodeOptions({ strength, targetLUFS, peakCeilingDBFS, maxGainDB }) {
  return new FfiWriter()
    .f64(strength)
    .f64(targetLUFS === null || targetLUFS === undefined ? NaN : targetLUFS)
    .f64(peakCeilingDBFS)
    .f64(maxGainDB)
    .done();
}

/** Result payload: `f32Array samples` (48 kHz mono), then `f64 sampleRate`,
 *  `f64 durationSec`, `f64 processingSec`, `f64 measuredLUFS`, and
 *  `f64 measuredTruePeakDBFS`. The two measurements are NaN when mastering was
 *  bypassed, which surfaces as null rather than as a NaN a caller has to know
 *  to test for. `r` is an FfiReader positioned at the payload. */
export function decodeResult(r) {
  const samples = r.f32Array();
  const sampleRate = r.f64();
  const durationSec = r.f64();
  const processingSec = r.f64();
  const measuredLUFS = r.f64();
  // Appended after the first release: a core built before it leaves nothing to
  // read, and the field reads as absent rather than as a decode failure.
  const measuredTruePeakDBFS = r.remaining >= 8 ? r.f64() : NaN;
  return {
    samples,
    sampleRate,
    durationSec,
    processingSec,
    measuredLUFS: Number.isNaN(measuredLUFS) ? null : measuredLUFS,
    measuredTruePeakDBFS: Number.isNaN(measuredTruePeakDBFS) ? null : measuredTruePeakDBFS,
    get realtimeFactor() {
      return processingSec > 0 ? durationSec / processingSec : 0;
    },
  };
}
