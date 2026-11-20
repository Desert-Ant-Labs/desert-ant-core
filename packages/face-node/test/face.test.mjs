import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import { Face, FaceDetector, Faceprint, Level } from "../node.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const RESOURCES = path.resolve(HERE, "../../../Tests/FaceTests/Resources");
const FIXTURE_DIR = path.join(HERE, "fixtures", "model");
const golden = JSON.parse(fs.readFileSync(path.join(RESOURCES, "face_golden.json"), "utf8"));

function photo(name) {
  const b = fs.readFileSync(path.join(RESOURCES, `${name}.rgb`));
  const width = b.readUInt32LE(0), height = b.readUInt32LE(4);
  return { data: new Uint8Array(b.buffer, b.byteOffset + 8, width * height * 3), width, height };
}

function unit(i) {
  const v = new Float32Array(128);
  v[i] = 1;
  return new Faceprint(v);
}

function noisy(person, seed) {
  let s = seed >>> 0;
  const rand = () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32) - 0.5;
  const v = new Float32Array(128);
  v[person] = 1;
  for (let i = 0; i < 128; i++) v[i] += rand() * 0.18;
  return { box: { x0: 0.1, y0: 0.1, x1: 0.3, y1: 0.3 }, landmarks: [], confidence: 0.9, faceprint: new Faceprint(v) };
}

test("faceprints compare by cosine and store in 512 bytes", () => {
  const a = new Faceprint([3, 4, ...new Array(126).fill(0)]);
  const b = new Faceprint([4, 3, ...new Array(126).fill(0)]);
  assert.ok(Math.abs(a.similarity(b) - 0.96) < 1e-6);
  assert.ok(a.isSamePerson(b) && a.isSamePerson(b, "strict"));
  assert.ok(!a.isSamePerson(unit(5)));
  assert.ok(!a.isSamePerson(new Faceprint(b.values, "face-0")), "different models never match");
  assert.equal(a.data.length, 512);
  assert.deepEqual(Array.from(Faceprint.fromData(a.data, a.model).values), Array.from(a.values));
  assert.deepEqual(Array.from(Faceprint.fromJSON(JSON.stringify(a)).values), Array.from(a.values));
  const mean = Faceprint.average([a, b]);
  assert.ok(Math.abs(mean.similarity(a) - mean.similarity(b)) < 1e-6);
  assert.equal(Faceprint.average([]), null);
  assert.ok(Level.recommended < Level.strict);
  assert.deepEqual(Face.matches(unit(0), [unit(0), unit(1)]).map((m) => m.index), [0]);
});

let face;
let loadError;
try {
  face = await Face.load(fs.existsSync(FIXTURE_DIR) ? { directory: FIXTURE_DIR } : {});
} catch (e) {
  loadError = e;
}
const modelOpts = face ? {} : { skip: `model unavailable: ${String(loadError).slice(0, 160)}` };

test("photos match the reference pipeline", modelOpts, async () => {
  for (const [file, want] of Object.entries(golden.photos)) {
    const got = await face.faces(photo(file.replace(".png", "")));
    assert.equal(got.length, want.faces.length, file);
    got.forEach((g, i) => {
      const w = want.faces[i];
      const ref = new Faceprint(w.embedding);
      assert.ok(g.faceprint.similarity(ref) > 0.98, `${file} faceprint ${g.faceprint.similarity(ref)}`);
      assert.ok(Math.abs(g.confidence - w.score) < 0.05, `${file} confidence`);
      assert.ok(Math.abs(g.box.x0 - w.box[0] / want.width) < 0.02, `${file} box`);
    });
  }
});

test("options filter the faces", modelOpts, async () => {
  const image = photo("group");
  assert.equal((await face.faces(image, { maxFaces: 1 })).length, 1);
  assert.equal((await face.faces(image, { minimumConfidence: 0.99 })).length, 0);
  await assert.rejects(face.faces({ data: new Uint8Array(5), width: 2, height: 2 }), TypeError);
});

test("a library of real photos", modelOpts, async () => {
  const library = await face.library();
  for (const name of ["single_a1", "single_a2", "single_b1", "group", "empty"]) {
    await library.add(await face.faces(photo(name)), name, { date: new Date(Date.UTC(2026, 0, 1)) });
  }
  await library.regroup();
  const people = await library.people();
  assert.deepEqual(people.map((p) => p.photoCount), [3, 2]);
  const a = (await library.face("single_a1#0")).person;
  assert.equal((await library.face("single_a2#0")).person, a);
  assert.equal(people[0].keyFace, people[0].faces[0]);
  const again = (await face.faces(photo("single_a2")))[0];
  assert.equal((await library.personFor(again.faceprint)).id, a);
  await library.name(a, "A");
  assert.deepEqual(await library.names(), { [a]: "A" });
  const record = await library.face("single_a1#0");
  assert.ok(record.date instanceof Date && record.faceprint instanceof Faceprint && record.confirmed);
  await library.close();
});

test("a library lives in your own database", modelOpts, async () => {
  const rows = new Map();
  const library = await face.library();
  let n = 0;
  for (let k = 0; k < 6; k++) {
    for (let p = 0; p < 3; p++) await library.addFace(noisy(p, 1000 + n), `row-${n++}`, `photo-${p}-${k}`);
  }
  await library.regroup();
  for (const r of await library.takeChanges()) rows.set(r.id, r);
  assert.equal(rows.size, 18);
  assert.deepEqual(await library.takeChanges(), []);
  const noor = rows.get("row-0").person;
  await library.name(noor, "Noor");
  await library.reject("row-3", noor);
  for (const r of await library.takeChanges()) rows.set(r.id, r);
  assert.equal(rows.get("row-3").person, undefined);
  assert.deepEqual(rows.get("row-3").rejected, [noor]);
  const names = await library.names();
  await library.close();

  const back = await face.library({
    faces: [...rows.values()].map((r) => ({ ...r, date: undefined, faceprint: r.faceprint.toJSON() })),
    names: Object.fromEntries(Object.entries(names)),
  });
  assert.deepEqual(await back.takeChanges(), []);
  await back.regroup();
  assert.equal((await back.person(noor)).name, "Noor");
  assert.notEqual((await back.face("row-3")).person, noor);
  const ana = await back.newPerson("row-3", "Ana");
  assert.ok(ana !== null && ana !== noor);
  await back.addFace(noisy(0, 99), "row-new", "new");
  assert.deepEqual((await back.takeChanges()).map((r) => r.id).sort(), ["row-3", "row-new"]);
  assert.equal((await back.face("row-new")).person, noor);
  const saved = await back.save();
  assert.equal(saved.faces.length, 19);
  await back.close();
  await assert.rejects(back.people());
});

test("the detector alone finds the faces Face finds, without faceprints", modelOpts, async () => {
  const detector = await FaceDetector.load(fs.existsSync(FIXTURE_DIR) ? { directory: FIXTURE_DIR } : {});
  try {
    for (const name of ["single_a1", "group", "empty"]) {
      const found = await detector.faces(photo(name), { minimumConfidence: 0.35 });
      const faces = await face.faces(photo(name));
      assert.deepEqual(found, faces.map(({ box, landmarks, confidence }) => ({ box, landmarks, confidence })), name);
    }
  } finally {
    detector.dispose();
  }
});

test("rows with dates reopen as a library", modelOpts, async () => {
  const library = await face.library();
  const date = new Date(1_700_000_000_000);
  for (let k = 0; k < 3; k++) await library.add([noisy(3, k)], `p${k}`, { date });
  await library.regroup();
  const rows = await library.takeChanges();
  assert.ok(rows.length === 3 && rows.every((r) => r.date instanceof Date));
  const reopened = await face.library({ faces: rows, names: await library.names() });
  assert.equal((await reopened.face("p0#0")).date.getTime(), date.getTime());
  await reopened.close();
  await library.close();
});
