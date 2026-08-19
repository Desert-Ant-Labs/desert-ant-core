// The model-specific half of this package's types. Everything that is the same
// for every model - how a model is loaded, how a call is billed and attributed -
// comes from @desert-ant-labs/core, so it is documented in one place.
import type { CallOptions, ModelLoadOptions } from "@desert-ant-labs/core";

/** A 2D point, in the same coordinate space as the input stroke. */
export interface Point {
  x: number;
  y: number;
}

/** A straight line segment. */
export interface LineShape {
  kind: "line";
  from: Point;
  to: Point;
}

/** A rectangle, as four corners in order around the perimeter. */
export interface RectangleShape {
  kind: "rectangle";
  corners: Point[];
}

/** A triangle, as its three vertices. */
export interface TriangleShape {
  kind: "triangle";
  vertices: Point[];
}

/** An ellipse with semi-axes and a rotation in radians. */
export interface EllipseShape {
  kind: "ellipse";
  center: Point;
  semiMajor: number;
  semiMinor: number;
  rotation: number;
}

/** A star alternating between `outerRadius` and `innerRadius`. */
export interface StarShape {
  kind: "star";
  center: Point;
  outerRadius: number;
  innerRadius: number;
  /** Rotation in radians. */
  rotation: number;
  pointCount: number;
}

/**
 * A recognized, fitted shape, discriminated by `kind`. The field names and kinds
 * are identical in Swift and Kotlin, so a stroke recognized on one platform
 * describes itself the same way on every other.
 */
export type Shape =
  | LineShape
  | RectangleShape
  | TriangleShape
  | EllipseShape
  | StarShape;

/** Options for a single recognition call. */
export interface RecognizeOptions extends CallOptions {
  /**
   * Minimum classifier confidence, on top of each class's calibrated gate
   * (default `0`, which applies only the model's own gates).
   */
  minimumConfidence?: number;
}

/**
 * How the model is loaded, from `@desert-ant-labs/core`: `directory` (Node) or
 * `modelBaseUrl` (browser) adopt self-hosted files, `onProgress` reports the
 * download, and the `litert*` / `accelerator` options tune the browser runtime.
 * Model-agnostic, so it is declared once in core rather than restated per model.
 */
export type LoadOptions = ModelLoadOptions;

/**
 * On-device single-stroke shape recognition for JavaScript. The default
 * `@desert-ant-labs/shapes` import is the browser WebAssembly + LiteRT.js build:
 * it has no native dependencies, so it builds cleanly for every target of a
 * multi-target bundler (Next, Remix, SvelteKit, Nuxt) and is safe to import
 * during server-side rendering. LiteRT.js initializes only in a browser or Web
 * Worker, so `Shapes.load()` runs inference in the browser; in plain Node it
 * throws and directs you to the native build. For server-side inference in Node
 * import `@desert-ant-labs/shapes/native` (a prebuilt native core, no
 * `@litertjs/core`) from server-only code. Both expose this same `Shapes` API.
 * Create one with `await Shapes.load(...)` and reuse it.
 *
 * ```ts
 * const shapes = await Shapes.load();
 * const shape = await shapes.recognize(points);   // Shape | null
 * if (shape?.kind === "ellipse") shape.center;
 * ```
 */
export declare class Shapes {
  /** Use Shapes.load(); the constructor is internal. */
  private constructor();
  /**
   * Load the model and return a ready recognizer. Downloads from the Hugging
   * Face Hub at the pinned revision and caches by default; pass `directory`
   * (Node) or `modelBaseUrl` (browser) to adopt self-hosted files instead.
   */
  static load(options?: LoadOptions): Promise<Shapes>;
  /**
   * Recognize one hand-drawn stroke, given either as `{x, y}` points or as a
   * flat `[x0, y0, x1, y1, ...]` sequence. Returns the fitted shape, or `null`
   * when the stroke is rejected or degenerate.
   */
  recognize(
    points: readonly Point[] | readonly number[],
    options?: RecognizeOptions,
  ): Promise<Shape | null>;
  /** Whether the model is usable with no network. */
  isDownloaded(): boolean;
  /**
   * Run `body` with a fresh call-group id, so every `recognize({ group })`
   * inside it bills as a single usage call. The group is released when `body`
   * settles.
   */
  withCallGroup<T>(body: (group: string) => Promise<T>): Promise<T>;
  /** Release the model. The recognizer is unusable afterwards. Both builds. */
  dispose(): void;
}
