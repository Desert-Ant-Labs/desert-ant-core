// Eye's FFI payload schemas: the image a run takes, the options beside it, and
// the analysis it returns. Both cores speak the same payloads (the native
// `dal_run` in node.js and the WebAssembly `run` in browser.js), so they live
// here once. Mirrors Sources/Eye/Binding.swift.
import { FfiWriter } from "@desert-ant-labs/core";
import { Analysis } from "./analysis.js";

/** The catalog id: how both cores are asked for Eye. */
export const MODEL_ID = "eye";

export const PACKAGE_NAME = "@desert-ant-labs/eye";

const PARTS = { photo: 1, layout: 2, faces: 4, sharpness: 8 };

/**
 * Normalize an image into `{ width, height, channels, bytes }`. Raw pixels are
 * `{ data, width, height }` (an `ImageData`, or RGB/RGBA bytes); in the browser
 * anything `createImageBitmap` takes (an `<img>`, canvas, `ImageBitmap`,
 * `VideoFrame`, `Blob`) is drawn to a canvas first.
 */
export async function toPixels(image) {
  if (image && image.data && image.width && image.height) {
    const { width, height } = image;
    const d = image.data;
    const bytes = d instanceof Uint8Array ? d
      : ArrayBuffer.isView(d) ? new Uint8Array(d.buffer, d.byteOffset, d.byteLength)
      : Uint8Array.from(d);
    const channels = bytes.length / (width * height);
    if (channels !== 3 && channels !== 4) {
      throw new TypeError(`image.data must hold ${width}x${height} RGB or RGBA bytes, got ${bytes.length}`);
    }
    return { width, height, channels, bytes };
  }
  if (typeof createImageBitmap === "function" && typeof OffscreenCanvas === "function") {
    const bitmap = image instanceof ImageBitmap ? image : await createImageBitmap(image);
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
    const context = canvas.getContext("2d");
    context.drawImage(bitmap, 0, 0);
    if (bitmap !== image) bitmap.close();
    return toPixels(context.getImageData(0, 0, canvas.width, canvas.height));
  }
  throw new TypeError("pass { data, width, height } with RGB or RGBA bytes (decode the image first, e.g. with sharp)");
}

/** Input payload: `u32 width`, `u32 height`, `u32 channels`, then the pixel blob. */
export function encodeInput({ width, height, channels, bytes }) {
  return new FfiWriter().u32(width).u32(height).u32(channels).blob(bytes).done();
}

/** Options payload: `u32 parts` (bits), `u32 maxFaces`. */
export function encodeOptions({ parts = Object.keys(PARTS), maxFaces = 20 } = {}) {
  let bits = 0;
  for (const part of parts) {
    if (!(part in PARTS)) throw new TypeError(`unknown part "${part}" (expected ${Object.keys(PARTS).join(", ")})`);
    bits |= PARTS[part];
  }
  if (!Number.isInteger(maxFaces) || maxFaces < 0) throw new TypeError("maxFaces must be a non-negative integer");
  return new FfiWriter().u32(bits).u32(maxFaces).done();
}

const dist = (r) => {
  const out = {};
  for (let n = r.u32(); n > 0; n--) out[r.str()] = r.f64();
  return out;
};
const box = (r) => ({ x0: r.f64(), y0: r.f64(), x1: r.f64(), y1: r.f64() });
const grid = (r) => ({ width: r.u32(), height: r.u32(), values: r.f32Array() });
const detections = (r) => {
  const out = [];
  for (let n = r.u32(); n > 0; n--) out.push({ label: r.str(), confidence: r.f64(), box: box(r) });
  return out;
};

function photo(r) {
  const p = { embedding: r.f32Array() };
  for (const k of ["type", "reject", "sensitive", "scenes", "rotation"]) p[k] = dist(r);
  p.aesthetic = r.f64();
  p.aestheticAttributes = dist(r);
  p.keeper = r.f64();
  p.cover = r.f64();
  p.blur = dist(r);
  p.bokeh = r.f64();
  p.pet = dist(r);
  p.peak = dist(r);
  return p;
}

function layout(r) {
  const attention = grid(r), people = detections(r), pets = detections(r), shot = dist(r);
  const flat = r.f32Array(), crops = [];
  for (let i = 0; i < flat.length; i += 5) {
    crops.push({ box: { x0: flat[i], y0: flat[i + 1], x1: flat[i + 2], y1: flat[i + 3] }, score: flat[i + 4] });
  }
  return { attention, people, pets, shot, crops };
}

function face(r) {
  const f = { box: box(r), confidence: r.f64(), landmarks: [] };
  for (let n = r.u32(); n > 0; n--) f.landmarks.push({ x: r.f64(), y: r.f64() });
  f.isFace = r.f64();
  f.isReal = r.f64();
  f.eyesOpen = r.f64();
  f.blink = dist(r);
  f.smile = r.f64();
  f.mouth = dist(r);
  f.expression = dist(r);
  f.looking = r.f64();
  f.occlusion = dist(r);
  f.sharp = r.f64();
  f.lighting = dist(r);
  f.keepsake = r.f64();
  f.pose = { yaw: r.f64(), pitch: r.f64(), roll: r.f64() };
  f.quality = r.f64();
  return f;
}

/** Result payload: the analysis as JSON, then its details, each part behind a `u32` present flag (see Binding.swift). */
export function decodeAnalysis(r) {
  const json = JSON.parse(r.str());
  return new Analysis(json, decodeDetails(r));
}

function decodeDetails(r) {
  const out = {};
  out.photo = r.u32() ? photo(r) : null;
  out.layout = r.u32() ? layout(r) : null;
  if (r.u32()) {
    out.faces = [];
    for (let n = r.u32(); n > 0; n--) out.faces.push(face(r));
  } else out.faces = null;
  out.sharpness = r.u32() ? { score: r.f64(), blurMap: grid(r) } : null;
  return out;
}
