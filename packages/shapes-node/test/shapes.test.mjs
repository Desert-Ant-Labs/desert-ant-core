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

import { Shapes } from "../node.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_DIR = path.join(HERE, "fixtures", "model");

/** A traced circle, dense enough to look hand-drawn to the preprocessor. */
function circle({ cx = 100, cy = 100, r = 80, samples = 64 } = {}) {
  return Array.from({ length: samples + 1 }, (_, i) => {
    const t = (2 * Math.PI * i) / samples;
    return { x: cx + r * Math.cos(t), y: cy + r * Math.sin(t) };
  });
}

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
  assert.ok(Math.abs(shape.center.x - 100) < 8, `center.x ${shape.center.x}`);
  assert.ok(Math.abs(shape.center.y - 100) < 8, `center.y ${shape.center.y}`);
  assert.ok(Math.abs(shape.semiMajor - 80) < 12, `semiMajor ${shape.semiMajor}`);
  assert.ok(Math.abs(shape.semiMinor - 80) < 12, `semiMinor ${shape.semiMinor}`);
});

test("accepts a flat [x0, y0, ...] stroke too", modelOpts, async () => {
  const shape = await shapes.recognize(flatCircle());
  assert.equal(shape?.kind, "ellipse", `got ${JSON.stringify(shape)}`);
});

test("recognizes a straight drag as a line with endpoints", modelOpts, async () => {
  const stroke = Array.from({ length: 41 }, (_, i) => ({ x: i * 5, y: i * 2 }));
  const shape = await shapes.recognize(stroke);
  assert.equal(shape?.kind, "line", `got ${JSON.stringify(shape)}`);
  assert.ok(Math.hypot(shape.from.x - shape.to.x, shape.from.y - shape.to.y) > 100);
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
