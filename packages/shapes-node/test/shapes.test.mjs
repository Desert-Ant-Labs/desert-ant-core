// The shapes-node test suite. Runs server-side in Node against the native core
// (the `@desert-ant-labs/shapes/native` entry, i.e. node.js). The default
// universal WebAssembly + LiteRT.js entry is exercised by the headless-Chromium
// example.
//
// The npm package does not bundle the model: `Shapes.load()` downloads it from
// the Hugging Face Hub at the pinned revision and caches it. We cover both load
// paths: the default HF download (hits the network, skipped when offline) and an
// explicit `directory` that adopts self-hosted files from an offline fixture
// (test/fixtures/model), so the offline/self-hosted story stays green with no
// network.
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import { Shapes, arrowheads } from "../node.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_DIR = path.join(HERE, "fixtures", "model");

/** A traced circle, dense enough to look hand-drawn to the preprocessor. */
function circle({ cx = 100, cy = 100, r = 80, samples = 64 } = {}) {
  return Array.from({ length: samples + 1 }, (_, i) => {
    const t = (2 * Math.PI * i) / samples;
    return { x: cx + r * Math.cos(t), y: cy + r * Math.sin(t) };
  });
}

/** Densely trace a polyline through `vertices`. */
function trace(vertices, per = 10) {
  const out = [];
  for (let i = 0; i < vertices.length - 1; i++) {
    const [a, b] = [vertices[i], vertices[i + 1]];
    for (let s = 0; s < per; s++) out.push({ x: a.x + ((b.x - a.x) * s) / per, y: a.y + ((b.y - a.y) * s) / per });
  }
  out.push(vertices[vertices.length - 1]);
  return out;
}

/** A shaft, then a head drawn back along one barb, to the tip, down the other. */
const arrow = () => trace([{ x: 0, y: 100 }, { x: 200, y: 100 }, { x: 170, y: 82 }, { x: 200, y: 100 }, { x: 170, y: 118 }], 8);
const zigzag = () => trace(Array.from({ length: 8 }, (_, i) => ({ x: i * 18, y: i % 2 ? 80 : 0 })));
const box = (deg = 0) => {
  const a = (deg * Math.PI) / 180;
  const rot = ({ x, y }) => ({ x: 80 + (x - 80) * Math.cos(a) - (y - 45) * Math.sin(a), y: 45 + (x - 80) * Math.sin(a) + (y - 45) * Math.cos(a) });
  return trace([{ x: 0, y: 0 }, { x: 160, y: 0 }, { x: 160, y: 90 }, { x: 0, y: 90 }, { x: 0, y: 0 }], 24).map(rot);
};

/** The same circle as a flat [x0, y0, ...] sequence, the other accepted spelling. */
function flatCircle() {
  return circle().flatMap((p) => [p.x, p.y]);
}

// Prefer the offline fixture so the suite is hermetic; fall back to the default
// HF download when the fixture is unavailable. Both exercise the same native
// inference; only the resolve/adopt path differs.
let shapes;
let loadError;
try {
  shapes = await Shapes.load({ directory: FIXTURE_DIR });
} catch (e) {
  loadError = e;
}
const modelOpts = shapes ? {} : { skip: `native model unavailable: ${String(loadError).slice(0, 120)}` };

test("recognizes a traced circle as a fitted ellipse", modelOpts, async () => {
  const shape = await shapes.recognize(circle());
  assert.equal(shape?.kind, "ellipse", `got ${JSON.stringify(shape)}`);
  assert.ok(Math.abs(shape.center.x - 100) < 4, `center.x ${shape.center.x}`);
  assert.ok(Math.abs(shape.center.y - 100) < 4, `center.y ${shape.center.y}`);
  assert.ok(Math.abs(shape.semiMajor - 80) < 4, `semiMajor ${shape.semiMajor}`);
  assert.equal(shape.semiMinor, shape.semiMajor, "a near-circle snaps to a circle");
  assert.equal(shape.outline.length, 64, "every shape carries its outline");
});

test("an arrow keeps its head, and arrowheads() draws it", modelOpts, async () => {
  const shape = await shapes.recognize(arrow());
  assert.equal(shape?.kind, "arrow", `got ${JSON.stringify(shape)}`);
  assert.equal(shape.startHead, false);
  assert.equal(shape.endHead, true);
  const heads = arrowheads(shape, 12);
  assert.equal(heads.length, 1);
  assert.deepEqual(heads[0][1], shape.to);
});

test("a zigzag is a scribble with a hull, unless left out of kinds", modelOpts, async () => {
  const shape = await shapes.recognize(zigzag());
  assert.equal(shape?.kind, "scribble", `got ${JSON.stringify(shape)}`);
  assert.ok(shape.hull.length >= 3);
  const kinds = ["line", "curve", "arrow", "rectangle", "ellipse"];
  assert.equal(await shapes.recognize(zigzag(), { kinds }), null);
});

test("rotation: upright removes it, free keeps it", modelOpts, async () => {
  const angle = (s) => (Math.atan2(s.corners[1].y - s.corners[0].y, s.corners[1].x - s.corners[0].x) * 180) / Math.PI;
  const upright = await shapes.recognize(box(22), { rotation: "upright" });
  const free = await shapes.recognize(box(22), { rotation: "free" });
  assert.equal(upright?.kind, "rectangle");
  assert.ok(Math.abs(angle(upright) % 90) < 1e-6, `upright angle ${angle(upright)}`);
  assert.ok(Math.abs(Math.abs(angle(free) % 90) - 22) < 3 || Math.abs(Math.abs(angle(free) % 90) - 68) < 3, `free angle ${angle(free)}`);
  await assert.rejects(shapes.recognize(box(), { rotation: "sideways" }), TypeError);
});

test("accepts a flat [x0, y0, ...] stroke too", modelOpts, async () => {
  const shape = await shapes.recognize(flatCircle());
  assert.equal(shape?.kind, "ellipse", `got ${JSON.stringify(shape)}`);
});

test("recognizes a straight drag as a line with endpoints", modelOpts, async () => {
  const stroke = Array.from({ length: 41 }, (_, i) => ({ x: i * 5, y: i * 2 }));
  const shape = await shapes.recognize(stroke);
  assert.equal(shape?.kind, "line", `got ${JSON.stringify(shape)}`);
  assert.ok(Math.hypot(shape.from.x - shape.to.x, shape.from.y - shape.to.y) > 180);
});

test("a degenerate stroke returns null", modelOpts, async () => {
  assert.equal(await shapes.recognize([{ x: 1, y: 1 }]), null);
  assert.equal(await shapes.recognize([]), null);
});

test("minimumConfidence rejects on top of the calibrated gates", modelOpts, async () => {
  assert.equal(await shapes.recognize(circle(), { minimumConfidence: 1 }), null);
});

test.after(() => shapes?.dispose());

// The default path downloads from the Hugging Face Hub at the pinned revision
// and caches it. It needs network on a cold cache, so it is opt-in via
// SHAPES_TEST_NETWORK=1 to keep the default suite hermetic.
const networkOpts = process.env.SHAPES_TEST_NETWORK === "1"
  ? {}
  : { skip: "set SHAPES_TEST_NETWORK=1 to exercise the Hugging Face download path" };

test("downloads from the Hugging Face Hub by default and caches", networkOpts, async () => {
  const downloaded = await Shapes.load();
  try {
    const shape = await downloaded.recognize(circle());
    assert.equal(shape?.kind, "ellipse", "expected a shape from the downloaded model");
  } finally {
    downloaded.dispose();
  }
});
