// Align's FFI payload schemas, mirroring the reader/writer in Sources/Align/Binding.swift.
import { FfiWriter } from "@desert-ant-labs/core";

/** The catalog id: how the native core is asked for Align. */
export const MODEL_ID = "align";

export const PACKAGE_NAME = "@desert-ant-labs/align";

/** The nine codes in the shipped refiner_config.json `languages` map. */
export const LANGUAGES = Object.freeze(["de", "en", "es", "fr", "it", "ja", "ko", "pt", "zh"]);

/** The same two-letter key rule as Swift's `Align.key`. */
export function languageKey(language) {
  return String(language).slice(0, 2).toLowerCase();
}

/** The time range a word may carry, in seconds: the same bounds as Swift's `Align.validate`. */
export const MIN_SECONDS = -1;
export const MAX_SECONDS = 10_000_000;

/**
 * Reject what the core cannot turn into a frame index, with a message naming the word. The core
 * checks the same rule, but its failure crosses the FFI as a bare "failed to run".
 */
export function validateInput(samples, sampleRate, words) {
  if (!samples?.length) throw new RangeError("align: the audio is empty");
  if (!(Number.isFinite(Number(sampleRate)) && Number(sampleRate) > 0)) {
    throw new RangeError(`align: sampleRate is ${sampleRate}, expected a finite positive rate`);
  }
  words.forEach((word, i) => {
    for (const key of ["start", "end"]) {
      // Number(), as the f64 write coerces: a numeric string was always accepted and still is.
      const t = Number(word[key]);
      if (!(Number.isFinite(t) && t >= MIN_SECONDS && t <= MAX_SECONDS)) {
        throw new RangeError(`align: word ${i} ${key} is ${word[key]}, expected a time from ${MIN_SECONDS} to ${MAX_SECONDS} seconds`);
      }
    }
  });
}

/** Input payload: `f32Array samples`, `f64 sampleRate`, `u32 wordCount`, then text/start/end per word. */
export function encodeInput(samples, sampleRate, words) {
  const w = new FfiWriter().f32Array(samples).f64(sampleRate).u32(words.length);
  for (const word of words) w.str(String(word.text)).f64(word.start).f64(word.end);
  return w.done();
}

/** Options payload: the language string. The core treats a code it does not know as a passthrough. */
export function encodeOptions({ language }) {
  return new FfiWriter().str(language).done();
}

/** Result payload: `u32 wordCount`, then `f64 start`, `f64 end`, `u32 refined` per word. */
export function decodeResult(r, words) {
  const n = r.u32();
  if (n !== words.length) throw new Error(`align: core returned ${n} words for ${words.length}`);
  return words.map((word) => {
    const start = r.f64(), end = r.f64(), refined = r.u32() === 1;
    return { ...word, start, end, refined };
  });
}
