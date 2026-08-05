// Redact's FFI payload schemas: the options a run takes and the result it
// returns.
//
// These are the only model-specific part of talking to the core, and both cores
// speak the same payloads - the native `dal_run` (node.js) and the WebAssembly
// `run` (browser.js) - so they live here once instead of in each entry point.
// Mirrors the reader/writer in Sources/Redact/Binding.swift.
import { FfiWriter } from "@desert-ant-labs/core";

/** The catalog id: how both cores are asked for Redact, and the key its
 *  WebAssembly exports are registered under. */
export const MODEL_ID = "redact";

export const PACKAGE_NAME = "@desert-ant-labs/redact";

/** The host global the WebAssembly core drives its LiteRT.js session through
 *  (matches `RedactModel.hostGlobal` in the Swift catalog). */
export const HOST_GLOBAL = "__RedactHost";

/** What a `modelBaseUrl` must serve, named as in the catalog: the artifact the
 *  host compiles itself, and the sidecars that cross into the core. */
export const MODEL_FILES = {
  model: "redact.tflite",
  sidecars: ["redact_tokenizer.bin", "labels.json"],
};

/** Options payload: `f64 minimumConfidence`, then a `u32` label count and that
 *  many length-prefixed names (an empty list means every label). */
export function encodeOptions({ minimumConfidence, labels }) {
  return new FfiWriter().f64(minimumConfidence).strings(labels ?? []).done();
}

/** Result payload: the redacted text, then a `u32` count and per item
 *  label/original/placeholder strings, an `f64` confidence, and `u32`
 *  start/end UTF-16 offsets. `r` is an FfiReader positioned at the payload.
 *  Returns the public `Redaction` shape, including `restore`. */
export function decodeRedaction(r) {
  const redactedText = r.str();
  const count = r.u32();
  const items = [];
  for (let i = 0; i < count; i++) {
    const label = r.str();
    const original = r.str();
    const placeholder = r.str();
    const confidence = r.f64();
    const start = r.u32();
    const end = r.u32();
    items.push({ label, original, placeholder, confidence, start, end });
  }
  return {
    redactedText,
    items,
    restore(processed) {
      let out = processed;
      for (const item of items) out = out.replaceAll(item.placeholder, item.original);
      return out;
    },
  };
}
