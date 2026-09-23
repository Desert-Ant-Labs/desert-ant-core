// Emo's FFI payload schemas: the options a run takes and the result it returns.
//
// Both cores (the native `dal_run` and the WebAssembly `run`) speak the same
// payloads, so they live here once.
// Mirrors the reader/writer in Sources/Emo/Binding.swift.
import { FfiWriter } from "@desert-ant-labs/core";

/** The catalog id: how both cores are asked for Emo, and the key its
 *  WebAssembly exports are registered under. */
export const MODEL_ID = "emo";

export const PACKAGE_NAME = "@desert-ant-labs/emo";

export const SKIN_TONES = {
  default: 0, light: 1, mediumLight: 2, medium: 3, mediumDark: 4, dark: 5,
};

/** Input payload: the phrase, length-prefixed UTF-8. Mirrors Emo's
 *  `run(input:options:)` in Sources/Emo/Binding.swift. */
export function encodeInput(text) {
  return new FfiWriter().str(text).done();
}

/** Options payload: `u32 limit`, `u32 skinTone`. */
export function encodeOptions({ limit, skinTone }) {
  return new FfiWriter().u32(limit).u32(skinTone).done();
}

/** Result payload: a `u32` count, then per suggestion a length-prefixed UTF-8
 *  emoji string and an IEEE-754 `f64` confidence. `r` is an FfiReader already
 *  positioned at the payload. */
export function decodeSuggestions(r) {
  const count = r.u32();
  const out = [];
  for (let i = 0; i < count; i++) {
    const emoji = r.str();
    const confidence = r.f64();
    out.push({ emoji, confidence });
  }
  return out;
}
