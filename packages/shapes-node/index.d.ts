// The model-specific half of this package's types. Everything that is the same
// for every model, such as how a model is loaded and its per-call options,
// comes from @desert-ant-labs/core, so it is documented in one place.
import type { CallOptions, ModelLoadOptions } from "@desert-ant-labs/core";
export { DesertAnt, type LogLevel } from "@desert-ant-labs/core";

/** A 2D point, in the same coordinate space as the input strokes. */
export interface Point {
  x: number;
  y: number;
}

/** One stroke of a drawing: its points in drawing order and, optionally, the
 *  time of each point in milliseconds, on one clock for the whole drawing. */
export interface Stroke {
  points: readonly Point[] | readonly number[];
  times?: readonly number[];
}

/** The polyline every shape has. A closed shape's outline doesn't repeat its
 *  first point. A connector's outline runs from start to end, and an arrow's
 *  outline is its shaft (see {@link arrowheads}). */
interface Drawable {
  outline: Point[];
  /** The polylines to draw: a plus's or a cross's two strokes, the outline for
   *  any other kind. */
  paths: Point[][];
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

/** A check mark: the end of the short arm, the corner, the end of the long arm. */
export interface CheckShape extends Drawable {
  kind: "check";
  start: Point;
  corner: Point;
  end: Point;
}

/** A cross or a plus: two straight strokes. A cross's first stroke is the one
 *  whose upper end is further left, each from its upper end. A plus's first
 *  stroke is the more level one, from its left end, then the more upright one,
 *  from its upper end. The outline is the first stroke, then the second. */
export interface CrossShape extends Drawable {
  kind: "cross" | "plus";
  firstFrom: Point;
  firstTo: Point;
  secondFrom: Point;
  secondTo: Point;
}

/** A bracket or brace: four points from its top end, through its two corners,
 *  to its other end. */
export interface BracketShape extends Drawable {
  kind: "bracket";
  points: Point[];
}

/** A zigzag, such as a highlight: from `from` to `to`, `|amplitude|` wide
 *  across, with `2 * teeth` straight runs. The sign of `amplitude` is the side
 *  the zigzag starts on: positive on the left of the direction of travel on a
 *  y-down canvas, negative on the right. */
export interface ZigzagShape extends Drawable {
  kind: "zigzag";
  from: Point;
  to: Point;
  amplitude: number;
  teeth: number;
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
  | ScribbleShape
  | CheckShape
  | CrossShape
  | BracketShape
  | ZigzagShape;

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
   * The kinds Shapes recognizes, all of them by default. For a drawing of any
   * other kind, `recognize` returns `null`. For example, leave out `"scribble"` if
   * your app has no erase gesture.
   */
  kinds?: readonly ShapeKind[];
  /**
   * The lowest model confidence Shapes accepts, on top of its own checks (default `0`,
   * which applies only its own checks).
   */
  minimumConfidence?: number;
  /**
   * `true` (the default) for the moment the pen lifts: a finished outline
   * snaps only once the whole outline is drawn, so a box missing a side comes
   * back `null`. Pass `false` for a preview while the pen still moves.
   */
  isFinished?: boolean;
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
 * Shapes turns a hand-drawn shape into a clean shape on the device: a line or
 * curve, an arrow, a rectangle, an ellipse, a triangle, a diamond, a pentagon,
 * a hexagon, a star, a heart, a cloud, a scribble (your app can use it as an
 * erase gesture), a check, a cross, a plus, a bracket, or a zigzag. The shape
 * can take a few strokes, such as a cross or a box drawn side by side. For
 * any other ink, `recognize` returns `null`, so you can keep it as ink.
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
 * else if (shape) draw(shape.paths);
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
  /**
   * Recognize a drawing of one or more strokes, in drawing order, such as a
   * plus drawn in two strokes. Give `times` for every stroke or for none:
   * without them, Shapes reads the strokes as drawn at a steady pace. Returns
   * the clean shape, or `null` for ink that isn't a shape.
   */
  recognize(
    strokes: readonly Stroke[],
    options?: RecognizeOptions,
  ): Promise<Shape | null>;
  /** Whether the model is usable with no network. */
  isDownloaded(): boolean;
  /** @deprecated Has no effect: runs `body` with a group id that nothing reads. */
  withCallGroup<T>(body: (group: string) => Promise<T>): Promise<T>;
  /** Wait for the license requests in flight, and send the device licenses that wait for their batch. */
  flushLicenses(): Promise<boolean>;
  /** Release the model. The recognizer is unusable afterwards. Both builds. */
  dispose(): void;
}
