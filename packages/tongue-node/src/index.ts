/**
 * tongue — on-device language identification for short text, across 84 languages.
 *
 * ```ts
 * import { Tongue } from "@desert-ant-labs/tongue";
 *
 * const tongue = await Tongue.load();
 * tongue.detect("kann ich das haben").language;   // "de"
 * ```
 *
 * One entry point for browser and Node, unlike emo's split build: there is no
 * wasm module and no inference runtime to swap, because a detection is arithmetic
 * — an int8 gather, a sum, one 59x32 matmul and a masked softmax. The only
 * platform difference is how the 2 MB weights are read, which `load` handles.
 */
import { normalize, MAX_CHARACTERS } from "./normalize.js";
import { route, type Route, type Verdict } from "./router.js";
import { Weights, type Metadata, type Prediction } from "./model.js";
import { UsageTurnstile } from "./usage.js";
// Resolved per platform by the "browser" condition in package.json, so a
// browser build contains no node: specifiers at all. See platform.browser.ts.
import { installUsageStorage, readModel } from "./platform.js";

export { normalize, MAX_CHARACTERS, route };
export type { Route, Verdict, Metadata, Prediction };
export { fnv1a, buckets, NGRAM_ORDERS } from "./hashing.js";

/**
 * How much to trust an answer.
 *
 * Keyed off evidence — input length and how far the top candidate leads the
 * runner-up — not raw softmax confidence, which is badly overconfident on very
 * short text. `"hi i am"` reads as Welsh to any character model at high
 * probability; the margin and the length are what reveal it as a guess.
 */
export type Reliability = "confident" | "likely" | "tentative" | "empty";

export interface Detection {
  readonly normalized: string;
  readonly candidates: readonly Prediction[];
  readonly reliability: Reliability;
  readonly route: Route;
  /** Top candidate, or `null` on empty input. */
  readonly language: string | null;
  /**
   * True when the top two ranked candidates are too close to separate. Present
   * both rather than crowning one: `"la casa"` is equally Italian and Spanish,
   * and saying so is more useful than picking. Detection ranks the runner-up
   * whatever `topK` is, so this holds even when one candidate was returned; ask
   * for two to show them.
   */
  readonly isTooCloseToCall: boolean;
}

/** Kept in step with package.json by `mise run set-version`. */
const SDK_VERSION = "3.4.0";

export interface LoadOptions {
  /** Directory or base URL holding tongue_int8.bin and tongue_meta.json. */
  readonly from?: string;
}

export class Tongue {
  /** One turnstile per instance. See usage.ts and docs/USAGE.md. */
  private readonly usage: UsageTurnstile;

  private constructor(
    private readonly metadata: Metadata,
    private readonly weights: Weights,
  ) {
    this.usage = UsageTurnstile.create(SDK_VERSION);
  }

  /** Load from explicit bytes — the platform-free path. */
  static fromBytes(metadata: Metadata, weightBytes: Uint8Array): Tongue {
    return new Tongue(metadata, new Weights(weightBytes, metadata));
  }

  /**
   * Load the model. Reads the bundled weights by default: on Node from the
   * package directory, in a browser by fetching relative to `options.from`.
   */
  /**
   * Load the model.
   *
   * On Node this reads the weights out of the package by default. In a browser
   * they are fetched, and there is nothing sensible to default to — a bundler
   * does not serve files out of node_modules — so pass `from`:
   *
   * ```ts
   * const tongue = await Tongue.load({ from: "/models/tongue" });
   * ```
   *
   * The two files to serve are exported for exactly this, so a bundler can
   * fingerprint them rather than needing a copy step:
   *
   * ```ts
   * import metaUrl from "@desert-ant-labs/tongue/model/tongue_meta.json?url";
   * ```
   */
  static async load(options: LoadOptions = {}): Promise<Tongue> {
    await installUsageStorage();
    const { metadata, bytes } = await readModel(options.from);
    return Tongue.fromBytes(metadata, bytes);
  }

  /** Identify the language of a short string. */
  detect(text: string, topK = 3): Detection {
    this.usage.record();
    const normalized = normalize(text);
    const routed = route(normalized);
    const finish = (
      candidates: readonly Prediction[],
      reliability: Reliability,
      evidence: readonly Prediction[] = candidates,
    ): Detection => ({
      normalized,
      candidates,
      reliability,
      route: routed,
      language: candidates[0]?.language ?? null,
      isTooCloseToCall:
        evidence.length > 1 &&
        evidence[0]!.probability - evidence[1]!.probability < 0.12,
    });

    if (!normalized) return finish([], "empty");
    // A script only one language uses needs no model, and no guessing is
    // involved, so it is always reported confident.
    if (routed.verdict === "decisive" && routed.candidates[0]) {
      return finish([{ language: routed.candidates[0], probability: 1 }], "confident");
    }

    const allowed =
      routed.verdict === "narrowing"
        ? this.metadata.labels.filter((label) => routed.candidates.includes(label))
        : (this.metadata.latin_labels ?? this.metadata.labels);
    if (allowed.length === 0) return finish([], "empty");

    // Rank the runner-up even when one candidate was asked for: the margin
    // between the top two is what reliability and the tie flag are made of.
    const ranked = this.weights.rank(normalized, new Set(allowed), topK === 1 ? 2 : topK);
    const candidates = topK === 1 ? ranked.slice(0, 1) : ranked;
    return finish(candidates, this.reliability(normalized, ranked), ranked);
  }

  /**
   * Send the usage this instance has recorded and await the POST, so a process
   * that ends right after a detection does not exit before it lands. Useful in a
   * short-lived script or worker, which has no idle gap for the debounce to fire
   * in. Usage is reported on its own; this is not required.
   *
   * Resolves true once the POST has finished, false only when the flush itself
   * threw. The endpoint's answer is not reported, as in core: reporting is best
   * effort.
   */
  async flushTelemetry(): Promise<boolean> {
    return this.usage.flushTelemetry();
  }

  private reliability(text: string, ranked: readonly Prediction[]): Reliability {
    const characters = [...text].length;
    const margin =
      ranked.length > 1
        ? ranked[0]!.probability - ranked[1]!.probability
        : (ranked[0]?.probability ?? 0);
    if (characters >= 18 && margin >= 0.3) return "confident";
    if (characters >= 12 && margin >= 0.2) return "likely";
    return "tentative";
  }
}
