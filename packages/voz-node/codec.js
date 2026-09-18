// Voz's package-level constants and the Hub URL its bundle is served from.
//
// Deliberately thin. Other models keep their FFI payload schemas here, because
// their options and results cross as bytes through one `run`; Voz's core exports
// a typed surface instead (`load`, `transcribe` in dist/bridge-js.d.ts), so
// there is nothing to encode.
//
// What a `modelBaseUrl` has to serve is NOT listed here. The core reports it
// from `Sources/Voz/Catalog.swift` through `modelInfo()`, so the file names
// cannot drift from the catalog the way a mirrored list does.

/** The catalog id: how the core is asked for Voz, and the key the bundle
 *  matrix looks for in a built bundle. */
export const MODEL_ID = "voz";

export const PACKAGE_NAME = "@desert-ant-labs/voz";

/** Mono 16 kHz is what the model's frontend takes. Anything else is resampled
 *  before it reaches the core. */
export const SAMPLE_RATE = 16000;

/**
 * Where a revision's browser bundle lives on the Hub.
 *
 * `resolve/<revision>/web/` rather than a release asset: the files are LFS
 * objects in the weights repo, and this is the URL that serves their contents.
 * `info` is what `modelInfo()` returned, so the repo and the revision come from
 * the catalog rather than from here.
 */
export function hubBaseUrl(info, revision = info.revision) {
  return `https://huggingface.co/${info.repo}/resolve/${revision}/web/`;
}
