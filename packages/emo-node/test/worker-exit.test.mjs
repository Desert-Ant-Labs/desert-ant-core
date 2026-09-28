// A worker thread that ends is not the process exiting: it must not drain the process's sessions or wait on their sends.
import assert from "node:assert/strict";
import { test } from "node:test";
import http from "node:http";
import { Worker } from "node:worker_threads";

// Accepts every request and never answers, so a send started by a worker's exit would hold it.
const held = [];
const server = http.createServer((req, res) => held.push(res));
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
process.env.DAL_INGEST_ENDPOINT = `http://127.0.0.1:${server.address().port}/api/v1/ingest`;

const { Emo } = await import("../node.js");
let emo;
try {
  emo = await Emo.load();
} catch {}
// Skipped locally when the model cannot load; in CI that is a failure.
const opts = emo || process.env.CI ? {} : { skip: "native emo model unavailable" };

function runWorker() {
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL("./worker-child.mjs", import.meta.url));
    let done = 0;
    worker.on("message", () => (done = Date.now()));
    worker.on("error", reject);
    worker.on("exit", (code) => resolve({ code, exitMs: done ? Date.now() - done : Infinity }));
  });
}

test("workers that load, dispose and end neither post nor wait", opts, async () => {
  assert.ok(emo, "the model did not load");
  // The main thread's session has already emitted, so a worker's calls are carried, not posted.
  await emo.suggestions("Pay my bills", { limit: 1 });
  void emo.flushTelemetry();
  for (let waited = 0; held.length < 1 && waited < 5000; waited += 50) await new Promise((r) => setTimeout(r, 50));
  assert.equal(held.length, 1, "the main thread's load did not post");

  for (let i = 0; i < 3; i++) {
    const result = await runWorker();
    assert.equal(result.code, 0, `worker ${i} exited ${result.code}`);
    assert.ok(result.exitMs < 1000, `worker ${i} took ${result.exitMs} ms to exit`);
  }
  await new Promise((r) => setTimeout(r, 300));
  assert.equal(held.length, 1, `${held.length - 1} posts came from worker exits`);
});

test.after(async () => {
  emo?.dispose();
  for (const res of held) res.destroy();
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
});
