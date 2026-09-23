// Moderator's FFI payload schemas: the image a run takes, the options beside it,
// and the result it returns. Both cores speak the same payloads (the native
// `dal_run` in node.js and the WebAssembly `run` in browser.js), so they live
// here once. Mirrors Sources/Moderator/Binding.swift.
import { FfiWriter } from "@desert-ant-labs/core";

/** The catalog id: how both cores are asked for Moderator. */
export const MODEL_ID = "moderator";

export const PACKAGE_NAME = "@desert-ant-labs/moderator";

const POLICIES = { standard: 0, allowTopless: 1 };
const QUALITIES = { fast: 0, balanced: 1, accurate: 2 };

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

/** Options payload: `f64 threshold`, `u32 policy`, `u32 quality`. */
export function encodeOptions({ threshold = 0.5, policy = "standard", quality = "accurate" } = {}) {
  if (!(policy in POLICIES)) throw new TypeError(`unknown policy "${policy}"`);
  if (!(quality in QUALITIES)) throw new TypeError(`unknown quality "${quality}"`);
  return new FfiWriter().f64(Number(threshold)).u32(POLICIES[policy]).u32(QUALITIES[quality]).done();
}

/** Result payload: `f64 score`, `u32 isNSFW`, then the five region `f64`s. */
export function decodeModeration(r) {
  const score = r.f64();
  const isNSFW = r.u32() === 1;
  const regions = {
    nipples: r.f64(), genitals: r.f64(), buttocks: r.f64(), nude: r.f64(), sexAct: r.f64(),
  };
  return { score, isNSFW, regions };
}
