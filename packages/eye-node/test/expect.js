// The comparison every Eye JavaScript suite makes against the reference
// analysis (Tests/EyeTests/Resources/eye_golden.json), with the Swift suite's
// tolerances: shared by the native test (Node) and the browser case's `check`.

/**
 * Tags agree with the reference's (want.tags, from ml-eye): the same tags computed, the same decision at both
 * cutoffs unless either confidence is within `margin` of the cutoff (runtimes differ a little), and close on average.
 */
export function expectSameTags(got, want, margin = 0.1) {
  const fail = (m) => { throw new Error(m); };
  const g = got.confidences, w = want.tags;
  const keys = Object.keys(w);
  if (Object.keys(g).length !== keys.length || keys.some((k) => !(k in g))) fail("tags computed differ from the reference's");
  let total = 0;
  for (const k of keys) {
    total += Math.abs(g[k] - w[k]);
    for (const cut of [0.5, 0.9]) {
      if ((g[k] >= cut) !== (w[k] >= cut) && Math.abs(g[k] - cut) > margin && Math.abs(w[k] - cut) > margin) {
        fail(`tag ${k}: ${g[k]} vs ${w[k]} at ${cut}`);
      }
    }
  }
  if (!(total / keys.length < 0.03)) fail(`tags differ by ${total / keys.length} on average`);
}

/** Throws on the first disagreement; `tolerance` is for probabilities. `got` is an Analysis with details. */
export function expectMatchesReference(analysis, want, tolerance = 0.08) {
  expectSameTags(analysis, want.tags);
  const got = analysis.details;
  const fail = (m) => { throw new Error(m); };
  const close = (g, w, tol, what) => {
    for (const k of Object.keys(w)) {
      if (!(Math.abs(g[k] - w[k]) < tol)) fail(`${what}.${k}: got ${g[k]}, want ${w[k]}`);
    }
  };
  const corr = (a, b) => {
    const ma = a.reduce((s, v) => s + v, 0) / a.length, mb = b.reduce((s, v) => s + v, 0) / b.length;
    let ab = 0, aa = 0, bb = 0;
    for (let i = 0; i < a.length; i++) { ab += (a[i] - ma) * (b[i] - mb); aa += (a[i] - ma) ** 2; bb += (b[i] - mb) ** 2; }
    return ab / Math.sqrt(aa * bb);
  };
  const iou = (a, b) => {
    const ix = Math.max(0, Math.min(a.x1, b[2]) - Math.max(a.x0, b[0])), iy = Math.max(0, Math.min(a.y1, b[3]) - Math.max(a.y0, b[1]));
    const inter = ix * iy;
    return inter / ((a.x1 - a.x0) * (a.y1 - a.y0) + (b[2] - b[0]) * (b[3] - b[1]) - inter);
  };

  const p = got.photo, wp = want.photo;
  const dot = Array.from(p.embedding).reduce((s, v, i) => s + v * wp.embedding[i], 0);
  if (!(dot > 0.98)) fail(`embedding cosine ${dot}`);
  for (const k of ["type", "reject", "sensitive", "scenes", "rotation", "blur", "pet", "peak"]) close(p[k], wp[k], tolerance, k);
  close(p.aestheticAttributes, wp.aestheticAttributes, 0.3, "aestheticAttributes");
  close(p, { aesthetic: wp.aesthetic, keeper: wp.keeper, cover: wp.cover }, tolerance, "photo");

  const l = got.layout, wl = want.layout;
  if (!(corr(Array.from(l.attention.values), wl.attention) > 0.95)) fail("attention map");
  // Core ML on the CPU (no Neural Engine, as on CI) drifts most here: 0.89 on this photo.
  if (!(corr(l.crops.map((c) => c.score), wl.crops) > 0.85)) fail("crop scores");
  close(l.shot, wl.shot, tolerance, "shot");
  // Clear of the threshold on both sides; boxes at IoU 0.6 (see EyeTests.swift).
  for (const [k, threshold] of [["people", 0.25], ["pets", 0.15]]) {
    for (const ref of wl[k].filter((d) => d.confidence > threshold + 0.05)) {
      if (!l[k].some((d) => d.label === ref.label && iou(d.box, ref.box) > 0.6)) fail(`${k}: missing ${JSON.stringify(ref)}`);
    }
    for (const d of l[k].filter((d) => d.confidence > threshold + 0.05)) {
      if (!wl[k].some((ref) => ref.label === d.label && iou(d.box, ref.box) > 0.6)) fail(`${k}: extra ${JSON.stringify(d)}`);
    }
  }

  if (got.faces.length !== want.faces.length) fail(`faces: ${got.faces.length} vs ${want.faces.length}`);
  for (const ref of want.faces) {
    const f = got.faces.reduce((best, f) => (iou(f.box, ref.box) > iou(best.box, ref.box) ? f : best));
    if (!(iou(f.box, ref.box) > 0.7)) fail(`no face matches ${ref.box}`);
    close(f, { eyesOpen: ref.eyesOpen, smile: ref.smile, looking: ref.looking, quality: ref.quality }, 0.1, "face");
    close(f.expression, ref.expression, 0.1, "face.expression");
    if (f.landmarks.length !== 5) fail("landmarks");
  }

  if (!(Math.abs(got.sharpness.score - want.sharpness.score) < 0.05)) fail("sharpness");
  if (!(corr(Array.from(got.sharpness.blurMap.values), want.sharpness.blurMap) > 0.95)) fail("blur map");
}
