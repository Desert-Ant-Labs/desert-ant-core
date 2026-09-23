// The moderator-node test suite. Runs server-side in Node against the native
// core (the `@desert-ant-labs/moderator/native` entry, i.e. node.js). The
// default browser entry is exercised by browser-case.js in headless Chromium.
//
// Expected scores are the reference goldens the Swift suite checks
// (Tests/ModeratorTests/Resources/moderator_golden.json), so the three SDKs are
// held to the same numbers. The model is adopted from test/fixtures/model when
// present (hermetic), else downloaded from the Hub at the pinned revision.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import { Moderator } from "../node.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const RESOURCES = path.resolve(HERE, "../../../Tests/ModeratorTests/Resources");
const FIXTURE_DIR = path.join(HERE, "fixtures", "model");
const golden = JSON.parse(fs.readFileSync(path.join(RESOURCES, "moderator_golden.json"), "utf8"));
const TOLERANCE = 0.02;

/** Deterministic RGB test pattern; same formula as the Swift suite and the golden script. */
function synthetic(width, height) {
  const data = new Uint8Array(width * height * 3);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 3;
      data[i] = ((x * 7 + y * 13) ^ (x * y)) & 255;
      data[i + 1] = (x * 3 + y * 5) & 255;
      data[i + 2] = ((x ^ y) * 11) & 255;
    }
  }
  return { data, width, height };
}

/** Minimal PNG decoder (8-bit gray/RGB/RGBA, non-interlaced) for the fixture. */
function decodePng(file) {
  const buf = fs.readFileSync(file);
  let pos = 8, width = 0, height = 0, colorType = 0;
  const idat = [];
  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos), type = buf.toString("latin1", pos + 4, pos + 8);
    const body = buf.subarray(pos + 8, pos + 8 + len);
    if (type === "IHDR") {
      width = body.readUInt32BE(0); height = body.readUInt32BE(4); colorType = body[9];
      assert.equal(body[8], 8); assert.equal(body[12], 0);
    } else if (type === "IDAT") idat.push(body);
    pos += 12 + len;
  }
  const bpp = { 0: 1, 2: 3, 6: 4 }[colorType];
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = width * bpp, out = new Uint8Array(height * stride);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)], row = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    for (let i = 0; i < stride; i++) {
      const a = i >= bpp ? out[y * stride + i - bpp] : 0, b = y ? out[(y - 1) * stride + i] : 0;
      const c = i >= bpp && y ? out[(y - 1) * stride + i - bpp] : 0;
      const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
      const pred = [0, a, b, (a + b) >> 1, pa <= pb && pa <= pc ? a : pb <= pc ? b : c][filter];
      out[y * stride + i] = (row[i] + pred) & 255;
    }
  }
  if (bpp !== 1) return { data: out, width, height };
  const rgb = new Uint8Array(width * height * 3);
  out.forEach((v, i) => rgb.set([v, v, v], i * 3));
  return { data: rgb, width, height };
}

function assertClose(got, want) {
  for (const k of ["nipples", "genitals", "buttocks", "nude", "sexAct"]) {
    assert.ok(Math.abs(got[k] - want[k]) < TOLERANCE, `${k}: got ${got[k]}, want ${want[k]}`);
  }
}

let moderator;
let loadError;
try {
  moderator = await Moderator.load(fs.existsSync(FIXTURE_DIR) ? { directory: FIXTURE_DIR } : {});
} catch (e) {
  loadError = e;
}
const modelOpts = moderator ? {} : { skip: `model unavailable: ${String(loadError).slice(0, 160)}` };

for (const quality of ["fast", "balanced", "accurate"]) {
  test(`synthetic image matches the reference (${quality})`, modelOpts, async () => {
    const { width, height } = golden.synthetic;
    const result = await moderator.analyze(synthetic(width, height), { quality });
    assertClose(result.regions, golden.synthetic[quality]);
  });

  test(`swimwear fixture is safe (${quality})`, modelOpts, async () => {
    const result = await moderator.analyze(decodePng(path.join(RESOURCES, golden.sfw.file)), { quality });
    assertClose(result.regions, golden.sfw[quality]);
    assert.equal(result.isNSFW, false);
    assert.ok(result.score < 0.2, `score ${result.score}`);
  });
}

test("RGBA input scores like RGB", modelOpts, async () => {
  const { data, width, height } = synthetic(97, 61);
  const rgba = new Uint8ClampedArray(width * height * 4);
  for (let i = 0; i < width * height; i++) rgba.set([data[i * 3], data[i * 3 + 1], data[i * 3 + 2], 255], i * 4);
  const a = await moderator.analyze({ data, width, height });
  const b = await moderator.analyze({ data: rgba, width, height });
  assert.deepEqual(a, b);
});

test("threshold and policy only change the decision", modelOpts, async () => {
  const image = synthetic(golden.synthetic.width, golden.synthetic.height);
  const low = await moderator.analyze(image, { threshold: 0 });
  assert.equal(low.isNSFW, true);
  const topless = await moderator.analyze(image, { policy: "allowTopless" });
  const r = topless.regions;
  assert.equal(topless.score, Math.max(r.genitals, r.buttocks, r.nude, r.sexAct));
});

test("rejects malformed input", modelOpts, async () => {
  await assert.rejects(moderator.analyze({ data: new Uint8Array(5), width: 2, height: 2 }), TypeError);
  await assert.rejects(moderator.analyze(synthetic(8, 8), { policy: "nope" }), TypeError);
});

test.after(() => moderator?.dispose());
