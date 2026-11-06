// Toxic's FFI payload schemas: the text a run takes, the options beside it, and
// the analysis it returns. Both cores speak the same payloads (the native
// `dal_run` in node.js and the WebAssembly `run` in browser.js), so they live
// here once. Mirrors Sources/Toxic/Binding.swift.
import { FfiWriter } from "@desert-ant-labs/core";

/** The catalog id: how both cores are asked for Toxic. */
export const MODEL_ID = "toxic";

export const PACKAGE_NAME = "@desert-ant-labs/toxic";

/** The three heads that say what a text does. */
export const CONTENT_LABELS = ["HATEFUL", "ABUSIVE", "THREAT"];

/** The eight heads that say which group a hateful text is about. */
export const TARGET_LABELS = [
  "RACE", "RELIGION", "NATIONAL_ETHNIC_ORIGIN", "SEXUAL_ORIENTATION", "GENDER", "DISABILITY", "AGE", "OTHER",
];

export const LABELS = [...CONTENT_LABELS, ...TARGET_LABELS];

/** Input payload: the text, length-prefixed UTF-8. */
export function encodeInput(text) {
  if (typeof text !== "string") throw new TypeError("pass the text to analyze as a string");
  return new FfiWriter().str(text).done();
}

/**
 * Options payload: `u32 count`, then that many `(string label, f64 threshold)`
 * pairs replacing the model's default threshold for the head named. An empty
 * payload means the SDK defaults.
 */
export function encodeOptions({ thresholds } = {}) {
  const entries = Object.entries(thresholds ?? {});
  for (const [label, value] of entries) {
    if (!LABELS.includes(label)) throw new TypeError(`unknown label "${label}"`);
    if (!Number.isFinite(value)) throw new TypeError(`threshold for ${label} must be a finite number`);
  }
  const w = new FfiWriter().u32(entries.length);
  for (const [label, value] of entries) w.str(label).f64(Number(value));
  return w.done();
}

/**
 * Result payload: `u32 count`, then per head `string label`, `f64 score`,
 * `f64 threshold`, `u32 flagged`.
 */
export function decodeAnalysis(r) {
  const scores = {};
  const thresholds = {};
  const flagged = [];
  for (let n = r.u32(); n > 0; n--) {
    const label = r.str();
    scores[label] = r.f64();
    thresholds[label] = r.f64();
    if (r.u32() === 1) flagged.push(label);
  }
  const content = CONTENT_LABELS.filter((l) => flagged.includes(l));
  const targets = TARGET_LABELS.filter((l) => flagged.includes(l)).sort((a, b) => scores[b] - scores[a]);
  return { scores, thresholds, flagged, content, targets, isToxic: content.length > 0 };
}
