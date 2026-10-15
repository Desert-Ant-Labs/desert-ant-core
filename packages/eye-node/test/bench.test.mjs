// Throughput of the native Node entry, opt-in: EYE_BENCH=1 [EYE_BENCH_N=30] npm test.
// Prints one EYE_BENCH JSON line; the cases are bench.js's.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import { bench } from "./bench.js";

const RESOURCES = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../Tests/EyeTests/Resources");

test("throughput", { skip: process.env.EYE_BENCH ? false : "set EYE_BENCH=1" }, async () => {
  const { Eye } = await import("../node.js");
  const golden = JSON.parse(fs.readFileSync(path.join(RESOURCES, "eye_golden.json"), "utf8"));
  const gray = fs.readFileSync(path.join(RESOURCES, "eye_fixture.gray"));
  const { width, height } = golden.fixture;
  const data = new Uint8Array(width * height * 3);
  gray.forEach((v, i) => data.set([v, v, v], i * 3));
  const t = performance.now();
  const eye = await Eye.load(process.env.EYE_MODEL_DIR ? { directory: process.env.EYE_MODEL_DIR } : {});
  const loadMs = Math.round(performance.now() - t);
  try {
    const rows = await bench(eye, { data, width, height }, { n: Number(process.env.EYE_BENCH_N ?? 30) });
    console.log("EYE_BENCH " + JSON.stringify({ runtime: `node-native ${process.platform}-${process.arch}`, cpu: os.cpus()[0]?.model, load_ms: loadMs, ...rows }));
  } finally {
    eye.dispose();
  }
});
