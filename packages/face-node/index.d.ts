import type { ModelLoadOptions } from "@desert-ant-labs/core";

/** A rectangle in 0..1 of the image's width and height, origin at the top left. */
export interface Box { x0: number; y0: number; x1: number; y1: number }

/** A point in 0..1 of the image's width and height, origin at the top left. */
export interface Point { x: number; y: number }

/** Decoded pixels: RGB or RGBA bytes, row-major from the top left. An `ImageData` works as is. */
export interface Pixels { data: ArrayLike<number> | ArrayBufferView; width: number; height: number }

import type { Faceprint, LevelName } from "@desert-ant-labs/core";

export { Faceprint, Level, LevelName } from "@desert-ant-labs/core";
export { DesertAnt, type LogLevel } from "@desert-ant-labs/core";

/** A face `FaceDetector` found: where it is, without a faceprint. */
export interface FaceDetection {
  box: Box;
  /** Left eye, right eye, nose tip, left and right mouth corner. */
  landmarks: Point[];
  confidence: number;
}

/** A face `Face` found, with its faceprint. */
export interface DetectedFace {
  box: Box;
  /** Left eye, right eye, nose tip, left and right mouth corner. */
  landmarks: Point[];
  confidence: number;
  faceprint: Faceprint;
}

/** One face in a library: one row of your own faces table. */
export interface FaceRecord {
  id: string;
  photo: string;
  date?: Date;
  box?: Box;
  confidence: number;
  faceprint: Faceprint;
  person?: number;
  confirmed: boolean;
  rejected: number[];
}

/** A person in a library. */
export interface Person {
  id: number;
  name?: string;
  /** Their faces' ids, the clearest first. */
  faces: string[];
  photoCount: number;
  keyFace: string;
}

/** A library as saved, or built from your own rows: `faces` and `names` (person id as a string key). */
export interface SavedLibrary {
  faces: object[];
  names: Record<string, string>;
}

/** Which faces to keep: defaults 0.35 for `Face` and 0.3 for `FaceDetector`, 32 pixels and 20 faces. */
export interface FacesOptions {
  minimumConfidence?: number;
  minimumSize?: number;
  maxFaces?: number;
  /** On a server: the end-user device this call serves. Licensing counts one license a month for each. */
  deviceId?: string | (() => string);
}

/** The people in a set of photos, for a people view where the user sees, names and fixes faces. */
export declare class FaceLibrary {
  add(faces: DetectedFace[], photo: string, options?: { date?: Date | number }): Promise<void>;
  addFace(face: DetectedFace, id: string, photo: string, options?: { date?: Date | number }): Promise<void>;
  removePhoto(photo: string): Promise<void>;
  removeFace(id: string): Promise<void>;
  people(options?: { prominent?: boolean }): Promise<Person[]>;
  person(id: number): Promise<Person | null>;
  personFor(faceprint: Faceprint): Promise<Person | null>;
  face(id: string): Promise<FaceRecord | null>;
  suggestions(person: number, options?: { limit?: number }): Promise<string[]>;
  takeChanges(): Promise<FaceRecord[]>;
  names(): Promise<Record<number, string>>;
  name(person: number, name: string | null): Promise<void>;
  confirm(id: string, person: number): Promise<void>;
  reject(id: string, person: number): Promise<void>;
  newPerson(id: string, name: string): Promise<number | null>;
  merge(other: number, person: number): Promise<void>;
  regroup(): Promise<void>;
  save(): Promise<SavedLibrary>;
  close(): Promise<void>;
}

export type LoadOptions = ModelLoadOptions;

/** On-device face matching. Create one with `await Face.load()` and reuse it. */
export declare class Face {
  static load(options?: LoadOptions): Promise<Face>;
  faces(image: Pixels | ImageBitmapSource, options?: FacesOptions): Promise<DetectedFace[]>;
  library(saved?: SavedLibrary | null): Promise<FaceLibrary>;
  isDownloaded(): boolean;
  flushLicenses(): Promise<boolean>;
  dispose(): void;
  static matches(reference: Faceprint, faceprints: Faceprint[], options?: { level?: LevelName | number }): { index: number; similarity: number }[];
}

/** On-device face detection: where the faces are, without faceprints. Downloads Face's detector alone. */
export declare class FaceDetector {
  static load(options?: LoadOptions): Promise<FaceDetector>;
  faces(image: Pixels | ImageBitmapSource, options?: FacesOptions): Promise<FaceDetection[]>;
  isDownloaded(): boolean;
  flushLicenses(): Promise<boolean>;
  dispose(): void;
}
