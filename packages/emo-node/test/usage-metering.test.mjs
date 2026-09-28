// A call on the native core always posts to the ingest; its own process, since the core reads the environment once.
import assert from "node:assert/strict";
import { test } from "node:test";
import http from "node:http";
import { randomUUID } from "node:crypto";

const received = [];
const server = http.createServer((req, res) => {
  let data = "";
  req.on("data", (chunk) => (data += chunk));
  req.on("end", () => {
    received.push(JSON.parse(data));
    res.writeHead(202).end();
  });
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));

process.env.DAL_INGEST_ENDPOINT = `http://127.0.0.1:${server.address().port}/api/v1/ingest`;
process.env.DAL_APP_ID = `${process.env.DAL_APP_ID}.metering.${randomUUID()}`;

const { Emo } = await import("../node.js");
// A few attempts, so one Hub hiccup does not fail the run.
let emo;
let loadError;
for (let attempt = 0; attempt < 3 && !emo; attempt++) {
  try {
    emo = await Emo.load();
  } catch (error) {
    loadError = error;
    await new Promise((resolve) => setTimeout(resolve, 2000 * (attempt + 1)));
  }
}
// Skipped locally when the model cannot load; in CI that is a failure.
const opts = emo || process.env.CI ? {} : { skip: `native model unavailable: ${String(loadError).slice(0, 120)}` };

test("a call always posts to the ingest", opts, async () => {
  assert.ok(emo, `the model did not load: ${loadError}`);
  try {
    await emo.suggestions("Pay my bills", { limit: 1 });
    await emo.flushTelemetry();
    assert.equal(received.length, 1, "the call did not report");
    assert.equal(received[0].events[0].callCount, 1);
  } finally {
    emo.dispose();
  }
});

test.after(() => new Promise((resolve) => server.close(resolve)));
