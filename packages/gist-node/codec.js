// Gist's FFI payload schemas: the options a run takes and the result it returns.
//
// These are the only model-specific part of talking to the core, and both cores
// speak the same payloads - the native `dal_run` (node.js) and the WebAssembly
// `run` (browser.js) - so they live here once instead of in each entry point.
// Mirrors the reader/writer in Sources/Gist/Binding.swift.
import { FfiWriter } from "@desert-ant-labs/core";

/** The catalog id: how both cores are asked for Gist, and the key its
 *  WebAssembly exports are registered under. */
export const MODEL_ID = "gist";

export const PACKAGE_NAME = "@desert-ant-labs/gist";

/** Input payload: the text, length-prefixed UTF-8. Mirrors Gist's
 *  `run(input:options:)` in Sources/Gist/Binding.swift. */
export function encodeInput(text) {
  return new FfiWriter().str(text).done();
}

/**
 * Result payload: an `f64` tuned threshold, a `u32` count, then per topic a
 * length-prefixed UTF-8 slug, its display name, and an IEEE-754 `f64`
 * probability - the whole taxonomy, ordered by slug. `r` is an FfiReader
 * already positioned at the payload.
 *
 * The whole taxonomy rather than a ranked top-N because `scores()` is the
 * distribution itself and `channelTopics()` rolls many of them up here, with no
 * model involved. The threshold and the display names ride along so `classify()`
 * ranks exactly as Swift does without this package shipping `gist_config.json`
 * or `taxonomy.json`.
 */
export function decodeTagged(r) {
  const threshold = r.f64();
  const count = r.u32();
  const scores = {};
  const names = {};
  for (let i = 0; i < count; i++) {
    const slug = r.str();
    names[slug] = r.str();
    scores[slug] = r.f64();
  }
  return { threshold, scores, names };
}
