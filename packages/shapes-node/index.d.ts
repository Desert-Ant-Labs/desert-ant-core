// The model-specific half of this package's types. Everything that is the same
// for every model, such as how a model is loaded and its per-call options,
// comes from @desert-ant-labs/core, so it is documented in one place.
import type { CallOptions, ModelLoadOptions } from "@desert-ant-labs/core";

/** A 2D point, in the same coordinate space as the input stroke. */
export interface Point {
  x: number;
  y: number;
}

/** The polyline every shape has. A closed shape's outline doesn't repeat its
 *  first point. A connector's outline runs from start to end, and an arrow's
 *  outline is its shaft (see {@link arrowheads}). */
interface Drawable {
  outline: Point[];
}

/** A straight connector. */
export interface LineShape extends Drawable {
  kind: "line";
  from: Point;
  to: Point;
}

/** A curved connector, as a cubic Bezier. */
export interface CurveShape extends Drawable {
  kind: "curve";
  from: Point;
  control1: Point;
  control2: Point;
  to: Point;
}

/** A connector with a drawn head at one or both ends. The shaft is a cubic
 *  Bezier, and a straight arrow has its controls on the line. */
export interface ArrowShape extends Drawable {
  kind: "arrow";
  from: Point;
  control1: Point;
  control2: Point;
  to: Point;
  startHead: boolean;
  endHead: boolean;
}

/** Four corners in order around the perimeter. */
export interface RectangleShape extends Drawable {
  kind: "rectangle";
  corners: Point[];
}

/** An ellipse. `rotation`, in radians, is the angle of the `semiMajor` axis from +x. */
export interface EllipseShape extends Drawable {
  kind: "ellipse";
  center: Point;
  semiMajor: number;
  semiMinor: number;
  rotation: number;
}

/** A triangle, diamond (a rhombus), pentagon, or hexagon, with its vertices
 *  in order around the perimeter. */
export interface PolygonShape extends Drawable {
  kind: "triangle" | "diamond" | "pentagon" | "hexagon";
  vertices: Point[];
}

/** A star. At `rotation` 0, in radians, a tip points straight up. */
export interface StarShape extends Drawable {
  kind: "star";
  center: Point;
  outerRadius: number;
  innerRadius: number;
  rotation: number;
  pointCount: number;
}

/** A heart that fills a `width` by `height` box around `center`, with its point down. */
export interface HeartShape extends Drawable {
  kind: "heart";
  center: Point;
  width: number;
  height: number;
}

/** A cloud. `outline` is the closed outline of its bumps. */
export interface CloudShape extends Drawable {
  kind: "cloud";
}

/** The erase gesture. `hull` is the convex hull of the scribble. To erase,
 *  delete the content inside the hull. */
export interface ScribbleShape extends Drawable {
  kind: "scribble";
  hull: Point[];
}

/**
 * A recognized shape, discriminated by `kind`. The kinds and field names are
 * the same in Swift and Kotlin.
 */
export type Shape =
  | LineShape
  | CurveShape
  | ArrowShape
  | RectangleShape
  | EllipseShape
  | PolygonShape
  | StarShape
  | HeartShape
  | CloudShape
  | ScribbleShape;

/** Every kind `recognize` can return. */
export type ShapeKind = Shape["kind"];

/**
 * How Shapes snaps rotation. `"snapped"`, the default, rounds rotations to 15°
 * steps and snaps lines and edges within 5° of an axis onto it. `"upright"`
 * removes rotation: boxes and ellipses align with the axes, and stars have a
 * tip straight up. `"free"` keeps the shape as drawn and skips the snapping to
 * circles, squares, and regular polygons.
 */
export type Rotation = "snapped" | "upright" | "free";

/** Options for a single recognition call. */
export interface RecognizeOptions extends CallOptions {
  /** How Shapes snaps rotation (default `"snapped"`). */
  rotation?: Rotation;
  /**
   * The kinds Shapes recognizes, all 13 by default. For a stroke of any other
   * kind, `recognize` returns `null`. For example, leave out `"scribble"` if
   * your app has no erase gesture.
   */
  kinds?: readonly ShapeKind[];
  /**
   * The lowest classifier confidence Shapes accepts, on top of each kind's calibrated threshold
   * (default `0`, which applies only the model's own gates).
   */
  minimumConfidence?: number;
}

/**
 * An arrow's heads, each an open polyline `[barb, tip, barb]` with barbs
 * `length` long. For any other shape, the array is empty.
 */
export declare function arrowheads(shape: Shape, length: number): Point[][];

/**
 * How the model is loaded, from `@desert-ant-labs/core`: `directory` (Node) or
 * `modelBaseUrl` (browser) adopt self-hosted files, `onProgress` reports the
 * download, and the `litert*` / `accelerator` options tune the browser runtime.
 */
export type LoadOptions = ModelLoadOptions;

/**
 * Shapes turns a hand-drawn stroke into a clean shape on the device: a
 * connector, an arrow, a rectangle, an ellipse, a polygon, a star, a heart, a
 * cloud, or a scribble, which your app can use as an erase gesture. For any
 * other stroke, `recognize` returns `null`, so you can keep that stroke as ink.
 *
 * The default `@desert-ant-labs/shapes` import is the browser WebAssembly +
 * LiteRT.js build:
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
 * const shape = await shapes.recognize(points, { rotation: "upright" });
 * if (shape?.kind === "scribble") eraseUnder(shape.hull);
 * else if (shape) draw(shape.outline);
 * ```
 */
export declare class Shapes {
  /** Use Shapes.load(); the constructor is internal. */
  private constructor();
  /**
   * Load the model and return a ready recognizer. Downloads from Hugging Face
   * at the pinned revision and caches by default; pass `directory`
   * (Node) or `modelBaseUrl` (browser) to adopt self-hosted files instead.
   */
  static load(options?: LoadOptions): Promise<Shapes>;
  /**
   * Recognize one hand-drawn stroke, given either as `{x, y}` points or as a
   * flat `[x0, y0, x1, y1, ...]` sequence. Returns the clean shape, or `null`
   * for a stroke that isn't a shape.
   */
  recognize(
    points: readonly Point[] | readonly number[],
    options?: RecognizeOptions,
  ): Promise<Shape | null>;
  /** Whether the model is usable with no network. */
  isDownloaded(): boolean;
  /** @deprecated Has no effect: runs `body` with a group id that nothing reads. */
  withCallGroup<T>(body: (group: string) => Promise<T>): Promise<T>;
  /** Wait for the license requests in flight. */
  flushTelemetry(): Promise<boolean>;
  /** Release the model. The recognizer is unusable afterwards. Both builds. */
  dispose(): void;
}
