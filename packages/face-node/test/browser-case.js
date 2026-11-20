import { Faceprint } from "../faceprint.js";

const RESOURCES = "/Tests/FaceTests/Resources/";
const FIXTURE = "/packages/face-node/test/fixtures/web/";

async function photo(name) {
  const b = new Uint8Array(await (await fetch(`${RESOURCES}${name}.rgb`)).arrayBuffer());
  const v = new DataView(b.buffer);
  const width = v.getUint32(0, true), height = v.getUint32(4, true);
  return { data: b.subarray(8, 8 + width * height * 3), width, height };
}

async function rejects(promise) {
  try {
    await promise;
    return "resolved";
  } catch (e) {
    return e?.name ?? String(e);
  }
}

export async function run({ Face, FaceDetector }, { litert, litertWasmDir }) {
  const golden = await (await fetch(RESOURCES + "face_golden.json")).json();
  const selfHosted = (await fetch(FIXTURE + "face.tflite", { method: "HEAD" })).ok;
  const t0 = performance.now();
  const face = await Face.load({ litert, litertWasmDir, ...(selfHosted ? { modelBaseUrl: FIXTURE } : {}) });
  const out = { loadMs: Math.round(performance.now() - t0), photos: {}, golden: golden.photos };
  try {
    for (const file of Object.keys(golden.photos)) {
      const t = performance.now();
      const faces = await face.faces(await photo(file.replace(".png", "")));
      out.photos[file] = {
        ms: Math.round(performance.now() - t),
        faces: faces.map((f) => ({ box: f.box, confidence: f.confidence, faceprint: f.faceprint.toJSON() })),
      };
    }
    const library = await face.library();
    for (const name of ["single_a1", "single_a2", "single_b1", "group", "empty"]) {
      await library.add(await face.faces(await photo(name)), name);
    }
    await library.regroup();
    out.people = (await library.people()).map((p) => p.photoCount);
    out.sameA = (await library.face("single_a1#0")).person === (await library.face("single_a2#0")).person;
    out.badPixels = await rejects(face.faces({ data: new Uint8Array(5), width: 2, height: 2 }));
    await library.close();
    const detector = await FaceDetector.load({ litert, litertWasmDir, ...(selfHosted ? { modelBaseUrl: FIXTURE } : {}) });
    const group = await photo("group");
    const strip = ({ box, landmarks, confidence }) => ({ box, landmarks, confidence });
    out.detected = { alone: (await detector.faces(group, { minimumConfidence: 0.35 })).map(strip), withFace: (await face.faces(group)).map(strip) };
    out.detectorAgrees = JSON.stringify(out.detected.alone) === JSON.stringify(out.detected.withFace);
    detector.dispose();
  } finally {
    face.dispose();
  }
  out.afterDispose = await rejects(face.faces(await photo("single_a1")));
  return out;
}

export function check(r) {
  const fail = (m) => { throw new Error(m); };
  for (const [file, want] of Object.entries(r.golden)) {
    const got = r.photos[file].faces;
    if (got.length !== want.faces.length) fail(`${file}: ${got.length} faces, expected ${want.faces.length}`);
    got.forEach((g, i) => {
      const cos = Faceprint.fromJSON(g.faceprint).similarity(new Faceprint(want.faces[i].embedding));
      if (!(cos > 0.98)) fail(`${file}: faceprint cosine ${cos}`);
      if (!(Math.abs(g.confidence - want.faces[i].score) < 0.05)) fail(`${file}: confidence ${g.confidence}`);
    });
  }
  if (JSON.stringify(r.people) !== "[3,2]") fail(`people ${JSON.stringify(r.people)}`);
  if (!r.sameA) fail("A's two photos are not one person");
  if (!r.detectorAgrees) fail(`FaceDetector found other faces than Face: ${JSON.stringify(r.detected)}`);
  if (r.badPixels !== "TypeError") fail(`bad pixels: ${r.badPixels}`);
  if (r.afterDispose === "resolved") fail("faces after dispose() resolved");
}
