// Moderator's case for the browser inference harness (js/test/browser/run.mjs).
//
// `run` executes inside headless Chromium against the real browser entry: the
// Swift -> WebAssembly core plus LiteRT.js on moderator.tflite, downloaded from
// the Hub at the pinned revision exactly as a consumer's first page load does.
// It feeds images in every form a page has them (raw pixels, ImageData, <img>,
// <canvas>, ImageBitmap, Blob), exercises every option and error path, and times
// each quality. The positive fixture is a public-domain painting fetched from
// Wikimedia, never committed. `check` runs in Node on what `run` returns.

const RESOURCES = "/Tests/ModeratorTests/Resources/";
const QUALITIES = ["fast", "balanced", "accurate"];

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

async function imageElement(blob) {
  const img = new Image();
  img.src = URL.createObjectURL(blob);
  await img.decode();
  return img;
}

function canvasOf(img) {
  const canvas = document.createElement("canvas");
  canvas.width = img.naturalWidth;
  canvas.height = img.naturalHeight;
  canvas.getContext("2d").drawImage(img, 0, 0);
  return canvas;
}

async function rejects(promise) {
  try {
    await promise;
    return "resolved";
  } catch (e) {
    return e?.name ?? String(e);
  }
}

async function timed(fn) {
  const t = performance.now();
  const value = await fn();
  return { value, ms: Math.round(performance.now() - t) };
}

export async function run({ Moderator }, { litert, litertWasmDir }) {
  const golden = await (await fetch(RESOURCES + "moderator_golden.json")).json();
  const load = await timed(() => Moderator.load({ litert, litertWasmDir }));
  const moderator = load.value;
  const out = { loadMs: load.ms, isDownloaded: moderator.isDownloaded(), golden: {}, timings: {} };
  try {
    // Raw pixels at every quality, against the reference model.
    const syn = synthetic(golden.synthetic.width, golden.synthetic.height);
    out.synthetic = {};
    for (const q of QUALITIES) {
      out.synthetic[q] = (await moderator.analyze(syn, { quality: q })).regions;
      out.golden[`synthetic_${q}`] = golden.synthetic[q];
    }
    // RGBA and RGB spellings of the same pixels score identically.
    const rgba = new ImageData(syn.width, syn.height);
    for (let i = 0; i < syn.width * syn.height; i++) {
      rgba.data.set([syn.data[i * 3], syn.data[i * 3 + 1], syn.data[i * 3 + 2], 255], i * 4);
    }
    out.rgbaMatchesRgb =
      JSON.stringify(await moderator.analyze(rgba)) === JSON.stringify(await moderator.analyze(syn));

    // The SFW fixture as every image type a page can hold.
    const sfwBlob = await (await fetch(RESOURCES + golden.sfw.file)).blob();
    const img = await imageElement(sfwBlob);
    const canvas = canvasOf(img);
    const bitmap = await createImageBitmap(sfwBlob);
    const imageData = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height);
    out.sfwInputs = {};
    for (const [name, input] of Object.entries({ blob: sfwBlob, img, canvas, bitmap, imageData })) {
      out.sfwInputs[name] = await moderator.analyze(input);
    }
    for (const q of QUALITIES) {
      const t = await timed(() => moderator.analyze(img, { quality: q }));
      out.timings[`sfw_${img.naturalWidth}x${img.naturalHeight}_${q}`] = t.ms;
      out[`sfw_${q}`] = t.value.regions;
      out.golden[`sfw_${q}`] = golden.sfw[q];
    }

    // The positive fixture, downloaded, as a Blob and as an <img>.
    const posBlob = await (await fetch(golden.positive.url)).blob();
    const posImg = await imageElement(posBlob);
    out.positive = await moderator.analyze(posBlob);
    out.positiveImg = await moderator.analyze(posImg);
    out.golden.positive = golden.positive.accurate;
    out.positiveStrict = await moderator.analyze(posBlob, { threshold: 0.99 });
    out.positiveTopless = await moderator.analyze(posBlob, { policy: "allowTopless" });
    const t = await timed(() => moderator.analyze(posBlob));
    out.timings[`positive_${posImg.naturalWidth}x${posImg.naturalHeight}_accurate`] = t.ms;

    // Error paths.
    out.errors = {
      badPixels: await rejects(moderator.analyze({ data: new Uint8Array(5), width: 2, height: 2 })),
      badPolicy: await rejects(moderator.analyze(syn, { policy: "nope" })),
      badQuality: await rejects(moderator.analyze(syn, { quality: "nope" })),
    };
    out.api = {
      withCallGroup: typeof moderator.withCallGroup,
      flushTelemetry: typeof moderator.flushTelemetry,
    };
    out.grouped = await moderator.withCallGroup(async (group) =>
      (await moderator.analyze(syn, { group, quality: "fast" })).score);
  } finally {
    moderator.dispose();
  }
  out.afterDispose = await rejects(moderator.analyze(synthetic(8, 8)));
  return out;
}

export function check(r) {
  const fail = (m) => { throw new Error(m); };
  const close = (got, want, tol, what) => {
    for (const k of Object.keys(want)) {
      if (!(Math.abs(got[k] - want[k]) < tol)) fail(`${what}.${k}: got ${got[k]}, want ${want[k]}`);
    }
  };
  const max = (g) => Math.max(g.nipples, g.genitals, g.buttocks, g.nude, g.sexAct);

  // Not asserted: the browser core's model store is in memory (persistence is the
  // HTTP cache), so isDownloaded() reads false there for every model, Shapes too.
  if (typeof r.isDownloaded !== "boolean") fail("isDownloaded() is not a boolean");
  // 0.03, not the 0.02 of the native suites: LiteRT.js's wasm kernels land up
  // to 0.019 from the fp32 reference on these images, and the int8 file drifts
  // up to 0.04 (p99, per image) on a wider set, so 0.02 would flake on a runtime
  // update rather than on a regression.
  for (const q of QUALITIES) {
    close(r.synthetic[q], r.golden[`synthetic_${q}`], 0.03, `synthetic_${q}`);
    close(r[`sfw_${q}`], r.golden[`sfw_${q}`], 0.03, `sfw_${q}`);
  }
  if (!r.rgbaMatchesRgb) fail("RGBA and RGB inputs scored differently");

  const inputs = Object.entries(r.sfwInputs);
  for (const [name, m] of inputs) {
    if (m.isNSFW) fail(`the swimwear fixture was flagged via ${name}: ${JSON.stringify(m)}`);
    close(m.regions, inputs[0][1].regions, 1e-9, `sfw via ${name} vs ${inputs[0][0]}`);
  }

  // Browser JPEG decoding differs slightly from Pillow's.
  close(r.positive.regions, r.golden.positive, 0.05, "positive");
  if (!r.positive.isNSFW) fail(`the nude painting passed: ${JSON.stringify(r.positive)}`);
  close(r.positiveImg.regions, r.positive.regions, 1e-9, "positive via <img> vs Blob");
  if (r.positiveStrict.isNSFW) fail("threshold 0.99 still flagged");
  if (r.positiveStrict.score !== r.positive.score) fail("the threshold changed the score");
  const tr = r.positiveTopless.regions;
  if (r.positiveTopless.score !== Math.max(tr.genitals, tr.buttocks, tr.nude, tr.sexAct)) {
    fail("allowTopless did not drop nipples from the score");
  }
  if (r.positive.score !== max(r.positive.regions)) fail("standard score is not the max region");

  for (const [name, got] of Object.entries(r.errors)) {
    if (got !== "TypeError") fail(`${name}: expected TypeError, got ${got}`);
  }
  if (r.api.withCallGroup !== "function" || r.api.flushTelemetry !== "function") fail("API surface");
  if (!(r.grouped >= 0 && r.grouped <= 1)) fail(`grouped call returned ${r.grouped}`);
  if (r.afterDispose === "resolved") fail("analyze after dispose() resolved");
}
