// Usage call-group tests for the native (server-side) Node core. They show the
// two ways usage attributes to billed calls:
//
//   1. Default  — each suggestions() is its own billed call.
//   2. Grouped  — emo.withCallGroup(async (group) => { ...({ group }) }) bills
//                 every suggestion inside as a single call.
//
// The usage transport POSTs a `load` body fire-and-forget on a short debounce.
// We redirect it to a local capture server (DAL_INGEST_ENDPOINT) and read back
// the emitted callCount. A unique DAL_APP_ID per case gives a fresh turnstile
// namespace so the load actually emits. Env is set before the first run, since
// the native usage client reads it (getenv) when it is first built.
import assert from "node:assert/strict";
import { test } from "node:test";
import http from "node:http";
import { randomUUID } from "node:crypto";

// A one-shot server that captures the first POSTed usage body and resolves it.
function captureServer() {
  let resolveBody;
  const bodyPromise = new Promise((r) => (resolveBody = r));
  const server = http.createServer((req, res) => {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => {
      res.writeHead(200).end();
      resolveBody(JSON.parse(data));
    });
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      resolve({ port: server.address().port, body: bodyPromise, close: () => server.close() });
    });
  });
}

// Load Emo fresh with the capture endpoint + a unique app id already in the env,
// run `body(emo)`, and return the emitted callCount (waits out the ~3s debounce).
async function capturedCallCount(body) {
  const server = await captureServer();
  process.env.DAL_INGEST_ENDPOINT = `http://127.0.0.1:${server.port}/api/v1/ingest`;
  process.env.DAL_APP_ID = `ai.desertant.emo.callgroup.${randomUUID()}`;
  try {
    const { Emo } = await import(`../node.js?fresh=${randomUUID()}`);
    const emo = await Emo.load();
    await body(emo);
    const ingest = await server.body;   // debounce (~3s) fires the POST
    emo.dispose();
    return ingest.events?.[0]?.callCount;
  } finally {
    server.close();
    delete process.env.DAL_INGEST_ENDPOINT;
    delete process.env.DAL_APP_ID;
  }
}

let available = true;
try { const { Emo } = await import("../node.js"); (await Emo.load()).dispose(); }
catch { available = false; }
const opts = available ? {} : { skip: "native core unavailable" };

test("default: three suggestions bill as three usage calls", opts, async () => {
  const count = await capturedCallCount(async (emo) => {
    for (let i = 0; i < 3; i++) await emo.suggestions("Pay my bills", { limit: 1 });
  });
  assert.equal(count, 3);
});

test("grouped: three suggestions in a call group bill as one usage call", opts, async () => {
  const count = await capturedCallCount(async (emo) => {
    await emo.withCallGroup(async (group) => {
      for (let i = 0; i < 3; i++) await emo.suggestions("Pay my bills", { limit: 1, group });
    });
  });
  assert.equal(count, 1);
});
