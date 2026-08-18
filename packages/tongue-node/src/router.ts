// The script router: a zero-parameter layer that answers before the model runs.
// Ported from src/tongue_training/script.py; test/golden.test.ts holds this file
// to those semantics.

import { RANGES, DECISIVE, NARROWING, JAPANESE } from "./script-tables.js";

export type Verdict = "decisive" | "narrowing" | "ambiguous";

export interface Route {
  readonly verdict: Verdict;
  readonly candidates: readonly string[];
  readonly script: string | null;
}

export function scriptFor(codePoint: number): string | null {
  let low = 0;
  let high = RANGES.length - 1;
  let found = -1;
  while (low <= high) {            // last range whose start <= codePoint
    const mid = (low + high) >> 1;
    if (RANGES[mid]![0] <= codePoint) { found = mid; low = mid + 1; } else { high = mid - 1; }
  }
  if (found < 0 || codePoint > RANGES[found]![1]) return null;
  return RANGES[found]![2];
}

export function histogram(text: string): Map<string, number> {
  const counts = new Map<string, number>();
  for (const char of text) {
    const script = scriptFor(char.codePointAt(0)!);
    if (script) counts.set(script, (counts.get(script) ?? 0) + 1);
  }
  return counts;
}

/**
 * Best-supported script that clears the presence rule.
 *
 * Presence beats dominance for non-Latin scripts: Latin brand names embed in
 * Greek or Thai text constantly, while the reverse essentially never happens. So
 * a script only some languages use decides the route even when Latin characters
 * outnumber it — provided the evidence is substantial: at least half the scripted
 * characters, or at least two carrying a quarter of them.
 *
 * Ties break on the lexicographically greatest script name, matching Python's
 * `max((count, name))`. Insertion order would diverge on mixed-script input — the
 * exact bug that cost this port 2 of 119 golden vectors before it was found.
 */
export function presence(counts: Map<string, number>, among: ReadonlySet<string>): string | null {
  let scripted = 0;
  for (const count of counts.values()) scripted += count;
  if (scripted === 0) return null;

  let best: string | null = null;
  let bestCount = 0;
  for (const [script, count] of counts) {
    if (!among.has(script)) continue;
    if (count > bestCount || (count === bestCount && best !== null && script > best)) {
      best = script;
      bestCount = count;
    }
  }
  if (best === null) return null;
  const share = bestCount / scripted;
  return share >= 0.5 || (bestCount >= 2 && share >= 0.25) ? best : null;
}

export function dominantScript(text: string): string | null {
  const counts = histogram(text);
  if (counts.size === 0) return null;
  // Same tie-break as presence: highest count, then greatest name.
  return [...counts.entries()].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? 1 : -1))[0]![0];
}

const DECISIVE_KEYS: ReadonlySet<string> = new Set(Object.keys(DECISIVE));
const NARROWING_KEYS: ReadonlySet<string> = new Set(Object.keys(NARROWING));

/**
 * Route already-normalized text to a verdict and candidate set.
 *
 * Japanese is special-cased ahead of everything: Japanese mixes Han with kana, so
 * any kana settles it even when Han characters outnumber them. Without this,
 * kanji-heavy Japanese misroutes to Chinese.
 */
export function route(text: string): Route {
  const counts = histogram(text);
  if (counts.size === 0) return { verdict: "ambiguous", candidates: [], script: null };

  if ((counts.get("Hiragana") ?? 0) > 0 || (counts.get("Katakana") ?? 0) > 0) {
    return { verdict: "decisive", candidates: ["ja"], script: JAPANESE };
  }
  const decisive = presence(counts, DECISIVE_KEYS);
  if (decisive !== null) {
    return { verdict: "decisive", candidates: [DECISIVE[decisive]!], script: decisive };
  }
  const narrowing = presence(counts, NARROWING_KEYS);
  if (narrowing !== null) {
    return { verdict: "narrowing", candidates: NARROWING[narrowing]!, script: narrowing };
  }
  return { verdict: "ambiguous", candidates: [], script: dominantScript(text) };
}
