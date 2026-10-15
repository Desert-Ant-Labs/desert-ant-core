// The model-specific half of this package's types. Everything that is the same
// for every model - how a model is loaded, how a call is billed and attributed -
// comes from @desert-ant-labs/core, so it is documented in one place.
import type { CallOptions, ModelLoadOptions } from "@desert-ant-labs/core";
import type { TagId } from "./tags.js";

export { Tag, TagId } from "./tags.js";

/**
 * Decoded pixels: `width * height` RGB or RGBA bytes, row-major from the
 * top-left, upright. An `ImageData` satisfies it. Alpha is ignored.
 */
export interface Pixels {
  data: Uint8Array | Uint8ClampedArray | ArrayLike<number>;
  width: number;
  height: number;
}

/**
 * Anything `analyze` takes: raw {@link Pixels} everywhere, and in the browser
 * whatever `createImageBitmap` accepts.
 */
export type ImageInput = Pixels | ImageBitmapSource;

/** What an analysis computes: each part is one or more model runs. */
export type Part = "photo" | "layout" | "faces" | "sharpness";

/** Options for a single `analyze` call. */
export interface AnalyzeOptions extends CallOptions {
  /**
   * What to compute. Default: all four. `"layout"` gates pet boxes by the
   * photo's scenes, so it runs the photo part too.
   */
  parts?: Part[];
  /** At most this many faces are analyzed, the most confident first. Default `20`. */
  maxFaces?: number;
}

/** Scores by name. */
export type NamedScores = Record<string, number>;

/** A tag id: one of {@link TagId}, or any string a newer model adds. */
export type TagName = TagId | (string & {});

/** How sure a tag must be: "recommended" is a confidence of 0.5, "strict" 0.9, for every tag. */
export type Level = "recommended" | "strict";

/** An axis-aligned rectangle in `[0, 1]` of the image's size, origin top left. */
export interface Box {
  x0: number;
  y0: number;
  x1: number;
  y1: number;
}

/** A point in `[0, 1]` of the image's size, origin top left. */
export interface Point {
  x: number;
  y: number;
}

/** A map over the image, row-major from the top left. */
export interface Grid {
  width: number;
  height: number;
  values: Float32Array;
}

/** The photo function's raw outputs, from the centre crop. */
export interface Photo {
  /** 512 dimensions, unit length: a dot product is a cosine similarity. */
  embedding: Float32Array;
  /** `photo`, `selfie`, `screenshot`, `receipt`, ...: probabilities that sum to 1. */
  type: NamedScores;
  /** `forgettable`, `accidental`, `technical_flaw`, ... (`keeper` the opposite), each 0 to 1. */
  reject: NamedScores;
  /** `nsfw_explicit`, `blood_injury`, `weapon`, ..., each 0 to 1. */
  sensitive: NamedScores;
  /** 565 Open Images classes (`Person`, `Dog`, `Beach`, ...), each 0 to 1. */
  scenes: NamedScores;
  /**
   * How far the photo is turned clockwise from upright, keyed `"0"`, `"90"`,
   * `"180"`, `"270"`: probabilities that sum to 1.
   */
  rotation: NamedScores;
  /** How good the photo is as a photograph, 0 to 1. */
  aesthetic: number;
  /** Ratings from 1 (poor) to 5 (excellent): `composition`, `lighting`, `color`, ... */
  aestheticAttributes: NamedScores;
  /** Whether people keep a photo like this, 0 to 1. */
  keeper: number;
  /** Whether it would make a good cover or thumbnail, 0 to 1. */
  cover: number;
  /** `none`, `defocus`, `motion`: probabilities that sum to 1. */
  blur: NamedScores;
  /** Deliberate background blur; higher is more. A score, not a probability. */
  bokeh: number;
  /** For a pet photo: `quality`, `face_visible`, `facing_camera`, `eyes_open`, `sharp`, `cut_off`, `occluded`. */
  pet: NamedScores;
  /** `airborne`, `peak`, `action`, `dramatic`, each 0 to 1. */
  peak: NamedScores;
}

/** One detected object. */
export interface Detection {
  /** `person`, `cat` or `dog`. */
  label: string;
  confidence: number;
  box: Box;
}

/** The spatial function's raw outputs, from the whole frame. */
export interface Layout {
  /** Where people look when they see the photo: 64x64, sums to 1. */
  attention: Grid;
  people: Detection[];
  /** Cats and dogs. */
  pets: Detection[];
  /** How the main person is framed: `extreme_close_up`, `close_up`, `medium`, `wide`. */
  shot: NamedScores;
  /** Every crop candidate with its score (higher is better), in the model's order. */
  crops: { box: Box; score: number }[];
}

/** One detected face and how it looks. */
export interface FaceDetails {
  box: Box;
  confidence: number;
  /** Left to right in the image: left eye, right eye, nose tip, left and right mouth corners. */
  landmarks: Point[];
  isFace: number;
  /** A real face rather than a statue, painting or screen. */
  isReal: number;
  eyesOpen: number;
  /** How closed each eye is: `left`, `right`. */
  blink: NamedScores;
  smile: number;
  /** `closed`, `talking`, `laughing`, `other_open`. */
  mouth: NamedScores;
  /** `neutral`, `happy`, `surprised`, `awkward_or_grimace`, `sad_or_angry`. */
  expression: NamedScores;
  /** Looking into the camera. */
  looking: number;
  /** `sunglasses`, `face_mask`, `hand_or_object_covering`, `cut_off_by_frame`. */
  occlusion: NamedScores;
  /** The face is in focus. */
  sharp: number;
  /** `good`, `dark`, `overexposed`, `harsh_shadows`. */
  lighting: NamedScores;
  /** A shot of this face worth keeping. */
  keepsake: number;
  /** Degrees. */
  pose: { yaw: number; pitch: number; roll: number };
  quality: number;
}

/** How sharp the photo is. */
export interface Sharpness {
  /** The probability that a person calls the photo sharp. */
  score: number;
  /** Blur over the image, higher is blurrier. */
  blurMap: Grid;
}

/** The model's raw outputs behind an {@link Analysis}; a part not asked for is `null`. Not stored. */
export interface Details {
  photo: Photo | null;
  layout: Layout | null;
  /** In the order of `Analysis.faces`. */
  faces: FaceDetails[] | null;
  sharpness: Sharpness | null;
}

/** A crop candidate and how good a crop it is (higher is better). */
export interface Crop {
  box: Box;
  score: number;
}

/** Percentiles in [0, 1] against the calibration set (0.5 is the median photo). */
export interface Scores {
  /** How good the photo is as a photograph. */
  aesthetic: number;
  /** How likely people are to keep a photo like this. */
  keeper: number;
  /** How well it would work as a cover or thumbnail. */
  cover: number;
}

/** One face in the photo, with its tags (`eyes_closed`, `smiling`, `looking_at_camera`, ...). */
export declare class Face {
  box: Box;
  /** How sure the detector is that this is a face, [0, 1]. */
  detectionConfidence: number;
  /** Left eye, right eye, nose tip, left and right mouth corners. */
  landmarks: Point[];
  pose: { yaw: number; pitch: number; roll: number };
  /** Overall quality of the face in this photo, [0, 1]. */
  quality: number;
  /** Every face tag with its confidence. */
  confidences: Record<string, number>;
  confidence(tag: TagName): number | null;
  has(tag: TagName, level?: Level): boolean;
}

/**
 * What Eye found in one photo: tags with confidences (0.5 the recommended cutoff, 0.9 strict, for every tag),
 * scores, people, pets, faces, a crop, a rotation fix and an embedding. `JSON.stringify` stores it (everything but
 * `details`) in the schema every SDK reads; {@link Analysis.fromJSON} restores it.
 */
export declare class Analysis {
  /** The model that produced it (`"eye@v1.0.0"`). */
  model: string;
  width: number;
  height: number;
  /** Every tag computed, with its confidence. A tag whose part was not computed is absent. */
  confidences: Record<string, number>;
  /** The most likely photo type: "photo", "selfie", "screenshot", "document", "receipt", ... */
  kind: TagName | null;
  scores: Scores | null;
  /**
   * How far the photo is turned clockwise from upright (90, 180 or 270), so turning it back counterclockwise by this
   * much makes it upright. Null when it is upright or Eye is unsure.
   */
  rotation: number | null;
  /** 512 numbers, unit length; see `similarity`. */
  embedding: Float32Array | null;
  people: Detection[] | null;
  /** Cats and dogs. */
  pets: Detection[] | null;
  faces: Face[] | null;
  /** The best crops, best first; see `bestCrop`. */
  crops: Crop[] | null;
  /** The model's raw outputs; null for a restored analysis. */
  details: Details | null;
  /** An analysis stored with `JSON.stringify` (or by the Swift or Kotlin SDK). */
  static fromJSON(json: string | object): Analysis;
  /** The photo's confidence for `tag`, null when it was not computed. */
  confidence(tag: TagName): number | null;
  /** Whether `tag` reaches `level` (default "recommended"). */
  has(tag: TagName, level?: Level): boolean;
  /** The tags at or above `level`, most confident first. */
  tags(level?: Level): TagName[];
  /** The best crop with this width-to-height ratio (1 square, 16 / 9 a banner), in [0, 1] of the image. */
  bestCrop(aspect: number): Box | null;
  /** Cosine similarity of the two embeddings, [-1, 1]; near-duplicates are above about 0.9. */
  similarity(other: Analysis): number | null;
  toJSON(): object;
}

/**
 * How the model is loaded, from `@desert-ant-labs/core`: `directory` (Node) or
 * `modelBaseUrl` (browser) adopt self-hosted files, `onProgress` reports the
 * download, and the `litert*` / `accelerator` options tune the browser runtime.
 */
export type LoadOptions = ModelLoadOptions;

/**
 * On-device photo understanding for JavaScript. The default
 * `@desert-ant-labs/eye` import is the browser WebAssembly + LiteRT.js build and
 * is safe to import during server-side rendering; for server-side inference in
 * Node import `@desert-ant-labs/eye/native` from server-only code. Both expose
 * this same API.
 *
 * ```ts
 * const eye = await Eye.load();
 * const photo = await eye.analyze(imageData);
 * if (photo.has(Tag.dog) && !photo.has(Tag.blurry)) keep(photo);
 * ```
 */
export declare class Eye {
  /** Use Eye.load(); the constructor is internal. */
  private constructor();
  /**
   * Load the model and return a ready eye. Downloads from Hugging Face at the
   * pinned revision and caches by default; pass `directory` (Node) or
   * `modelBaseUrl` (browser) to adopt self-hosted files instead.
   */
  static load(options?: LoadOptions): Promise<Eye>;
  /** Analyze an image. */
  analyze(image: ImageInput, options?: AnalyzeOptions): Promise<Analysis>;
  /** Send recorded usage and await the POST. */
  flushTelemetry(): Promise<boolean>;
  /** Whether the model is usable with no network. */
  isDownloaded(): boolean;
  /**
   * Run `body` with a fresh call-group id, so every `analyze({ group })`
   * inside it bills as a single usage call.
   */
  withCallGroup<T>(body: (group: string) => Promise<T>): Promise<T>;
  /** Release the model. The eye is unusable afterwards. */
  dispose(): void;
  /**
   * Groups of near-duplicates, as indices into `analyses`, each at least two photos, best first. With `dates`
   * (capture times in seconds, any epoch), only photos taken within the model's window of each other count.
   */
  static duplicates(analyses: Analysis[], options?: { dates?: (number | null)[] }): number[][];
  /** The index of the photo to keep from a set: no closed eyes, then the best faces, then keeper. */
  static best(analyses: Analysis[]): number | null;
  /** Photos ranked by similarity to `photo`, most similar first. */
  static similar(photo: Analysis, analyses: Analysis[], options?: { limit?: number }): { index: number; similarity: number }[];
}
