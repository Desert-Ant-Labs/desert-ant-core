// Emo's FFI payload schemas: the options a run takes and the result it returns.
//
// These are the only model-specific part of talking to the core, and both cores
// speak the same payloads - the native `dal_run` (node.js) and the WebAssembly
// `run` (browser.js) - so they live here once instead of in each entry point.
// Mirrors the reader/writer in Sources/Emo/Binding.swift.
import { FfiWriter } from "@desert-ant-labs/core";

/** The catalog id: how both cores are asked for Emo, and the key its
 *  WebAssembly exports are registered under. */
export const MODEL_ID = "emo";

export const PACKAGE_NAME = "@desert-ant-labs/emo";

/** The host global the WebAssembly core drives its LiteRT.js session through
 *  (matches `EmoModel.hostGlobal` in the Swift catalog). */
export const HOST_GLOBAL = "__EmoHost";

/** What a `modelBaseUrl` must serve, named as in the catalog: the artifact the
 *  host compiles itself, and the sidecars that cross into the core. */
export const MODEL_FILES = {
  model: "emo.tflite",
  sidecars: ["emo_meta.json", "emo_tokenizer.bin"],
};

export const SKIN_TONES = {
  default: 0, light: 1, mediumLight: 2, medium: 3, mediumDark: 4, dark: 5,
};

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
