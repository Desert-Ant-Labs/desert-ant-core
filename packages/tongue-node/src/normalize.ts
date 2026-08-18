// The pinned input normalizer, ported from src/tongue_training/normalize.py.
//
// That module is a frozen specification, not an implementation detail: this file
// must reproduce its output exactly, or the model sees different features here
// than it was trained on. The contract is docs/normalizer.md plus
// test/normalize_vectors.json, copied from the reference repo's golden/ and
// replayed by test/golden.test.js.
//
// Porting hazards this file is deliberate about:
//
//   NFC, not NFKC. Canonical composition only. NFKC also folds compatibility
//     characters ("ﬁ" -> "fi", "½" -> "1⁄2"), changing the character sequence and
//     therefore every n-gram derived from it.
//   Code-point truncation. Python slices by code point, so the 512 cap counts
//     code points. `String.prototype.slice` counts UTF-16 units and would cut
//     astral characters in half.
//   Unicode property escapes. `\p{...}` needs the `u` flag; the general-category
//     filter mirrors Python's `unicodedata.category`.

import { DISCARD_RANGES } from "./discard-table.js";

export const MAX_CHARACTERS = 512;

// Order is part of the contract; see `normalize`.
// Every class is spelled out. `\w`, `\d`, `\s` and `\S` are engine-defined and the
// three engines behind this spec disagree. This port already wrote the mention and
// digit classes out; `\s` and `\S` were still JavaScript's, which omits U+0085 and
// U+001C-001F and adds U+FEFF. Python's definition is the spec, and the same
// 29 scalars now appear in all three ports.
const WS = "\\u0009-\\u000D\\u001C-\\u0020\\u0085\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000";
const NON_WS = `[^${WS}]`;

const URL_RE = new RegExp(`(?:https?://|www\\.)${NON_WS}+`, "giu");
const EMAIL_RE = new RegExp(`${NON_WS}+@${NON_WS}+\\.${NON_WS}+`, "gu");
const MENTION_RE = /[@#][\p{L}\p{N}_]+/gu;
const DIGIT_RE = /\p{Nd}+/gu;
// Emoji, symbol modifiers and invisible formatting characters: no language
// signal, but they do perturb the n-gram bag. So, Sk, Cf, Co, Cn.
// From the pinned table rather than `\p{So}` and friends, because those answer
// from the engine's Unicode version and the model was trained on 13.0.0 — a newer
// V8 would otherwise keep scalars the training data discarded.
function isDiscarded(codePoint: number): boolean {
  let low = 0;
  let high = DISCARD_RANGES.length - 1;
  while (low <= high) {
    const mid = (low + high) >> 1;
    const [start, end] = DISCARD_RANGES[mid]!;
    if (codePoint < start) high = mid - 1;
    else if (codePoint > end) low = mid + 1;
    else return true;
  }
  return false;
}

function dropDiscarded(text: string): string {
  let out = "";
  for (const character of text) {
    if (!isDiscarded(character.codePointAt(0)!)) out += character;
  }
  return out;
}
const WHITESPACE_RE = new RegExp(`[${WS}]+`, "gu");

/**
 * Apply the frozen normalization pipeline.
 *
 * 1. Unicode NFC
 * 2. remove URLs, then emails, then @mentions and #hashtags
 * 3. remove digit runs
 * 4. remove symbol and format characters
 * 5. invariant lowercase
 * 6. collapse whitespace runs to one space and trim the ends
 * 7. truncate to MAX_CHARACTERS code points
 */
export function normalize(text: string): string {
  let result = text.normalize("NFC");
  result = result.replace(URL_RE, " ").replace(EMAIL_RE, " ").replace(MENTION_RE, " ");
  result = dropDiscarded(result.replace(DIGIT_RE, " "));
  result = result.toLowerCase();
  result = result.replace(WHITESPACE_RE, " ").trim();
  // Spread iterates by code point, so this truncates the way Python does.
  const codePoints = [...result];
  return codePoints.length > MAX_CHARACTERS
    ? codePoints.slice(0, MAX_CHARACTERS).join("")
    : result;
}

/** Whitespace tokens of already-normalized text. */
export function tokens(text: string): string[] {
  return text ? text.split(" ") : [];
}
