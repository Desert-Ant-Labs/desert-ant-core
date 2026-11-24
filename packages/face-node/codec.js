import { FfiWriter } from "@desert-ant-labs/core";

export const MODEL_ID = "face";

export const PACKAGE_NAME = "@desert-ant-labs/face";

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

const EMPTY = new Uint8Array(0);

export function encodeImage({ width, height, channels, bytes }) {
  return new FfiWriter().u32(width).u32(height).u32(channels).blob(bytes).done();
}

export function encodeCall(op, args = {}) {
  return new FfiWriter().str(op).str(JSON.stringify(args)).done();
}

export async function call(model, op, args = {}, image = null, deviceId = undefined) {
  const reader = await model.run(image ? encodeImage(image) : EMPTY, encodeCall(op, args), { deviceId });
  if (!reader || reader.remaining === 0) throw new Error(`${PACKAGE_NAME}: ${op} failed`);
  return JSON.parse(reader.str());
}
