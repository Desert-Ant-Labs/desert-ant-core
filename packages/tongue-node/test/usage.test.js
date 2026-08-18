import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { UsageClient, makeSend } from "../dist/usage.js";
import { Tongue } from "../dist/index.js";

// Replays the shared turnstile contract. The Kotlin port replays the identical
// file against its own hand-ported client; the Swift SDK uses desert-ant-core's
// client directly, which is where this behaviour comes from. See docs/USAGE.md.
const here = dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(readFileSync(join(here, "usage_vectors.json"), "utf8"));

test("turnstile matches the shared contract", () => {
  for (const c of vectors.cases) {
    let state = { lastActiveAt: c.stateLastActiveAt, carryCallCount: c.stateCarry };
    let now = 0;
    const sends = [];

    const client = new UsageClient({
      deviceId: "device-under-test",
      platform: "test",
      version: "0.0.0",
      windowMs: vectors.windowMs,
      now: () => now,
      loadState: () => state,
      saveState: (next) => {
        state = next;
      },
      send: (body) => sends.push(body),
    });

    c.stepKinds.forEach((kind, i) => {
      now = c.stepAt[i];
      if (kind === "start") client.start();
      else if (kind === "flush") client.flush();
      else if (kind === "record") client.recordCall(c.stepN[i]);
      else throw new Error(`unknown step ${kind}`);
    });

    assert.equal(sends.length, c.sendCounts.length, `${c.name}: send count`);
    c.sendCounts.forEach((expected, i) => {
      const event = sends[i].events[0];
      assert.equal(event.name, "load", `${c.name}: event name`);
      assert.equal(event.deviceId, "device-under-test", `${c.name}: deviceId`);
      assert.equal(event.callCount ?? -1, expected, `${c.name}: callCount[${i}]`);
    });
    assert.equal(state.lastActiveAt, c.finalLastActiveAt, `${c.name}: final lastActiveAt`);
    assert.equal(state.carryCallCount, c.finalCarry, `${c.name}: final carry`);
  }
});

test("detection still works with reporting switched off", async () => {
  // The suite runs with DAL_USAGE_DISABLED=1, so no client is wired up at all.
  const tongue = await Tongue.load();
  assert.equal(tongue.detect("kann ich das haben").language, "de");
});

test("the wire body matches core's field order and carries no text", () => {
  const sends = [];
  const client = new UsageClient({
    deviceId: "d",
    key: "k",
    appId: "com.acme.app",
    platform: "node",
    version: "9.9.9",
    windowMs: vectors.windowMs,
    now: () => 1700000000000,
    loadState: () => ({ lastActiveAt: 0, carryCallCount: 0 }),
    saveState: () => {},
    send: (body) => sends.push(body),
  });
  client.start();
  client.recordCall(2);
  client.flush();

  assert.equal(sends.length, 1);
  // Field order is part of the contract: Wire.kt builds the same bytes, and
  // JSON.stringify follows insertion order, so a reordered literal silently
  // diverges from the Kotlin port.
  assert.equal(
    JSON.stringify(sends[0]),
    '{"platform":"node","key":"k","app":{"id":"com.acme.app"},' +
      '"sdk":{"name":"tongue-js","version":"9.9.9"},' +
      '"sentAt":"2023-11-14T22:13:20.000Z",' +
      '"events":[{"name":"load","deviceId":"d","callCount":2}]}',
  );
});

test("DAL_USAGE_DISABLED suppresses every send and every store write", async () => {
  // The kill switch docs/USAGE.md offers operators. Nothing asserted it before,
  // so a regression making it a no-op would have shipped green and started
  // billing every CI runner.
  const { UsageTurnstile } = await import("../dist/usage.js");
  assert.equal(process.env.DAL_USAGE_DISABLED, "1", "suite must run with the switch on");
  assert.equal(UsageTurnstile.create("9.9.9"), null);

  let fetched = false;
  const realFetch = globalThis.fetch;
  globalThis.fetch = () => {
    fetched = true;
    return Promise.reject(new Error("must not be called"));
  };
  try {
    const tongue = await Tongue.load();
    for (let i = 0; i < 20; i++) tongue.detect("kann ich das haben");
    await new Promise((r) => setTimeout(r, 50));
    assert.equal(fetched, false, "a detection posted despite DAL_USAGE_DISABLED");
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("the transport actually posts the body over HTTP", async () => {
  // Everything else about the turnstile is tested with an injected `send`, so the
  // HTTP path itself had never run: no test proved a body ever left the process.
  // This drives the real transport at a local server. The destination stays
  // hardcoded for real use; only the test passes an endpoint.
  const { createServer } = await import("node:http");
  const received = [];
  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      received.push({ method: req.method, type: req.headers["content-type"], body });
      res.writeHead(204).end();
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();

  try {
    makeSend(`http://127.0.0.1:${port}/api/v1/ingest`)({
      platform: "node",
      key: "k",
      app: { id: "com.acme.app" },
      sdk: { name: "tongue-js", version: "9.9.9" },
      sentAt: "2023-11-14T22:13:20.000Z",
      events: [{ name: "load", deviceId: "d", callCount: 2 }],
    });

    const deadline = Date.now() + 5000;
    while (received.length === 0 && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 25));
    }
    assert.equal(received.length, 1, "the transport never reached the server");
    assert.equal(received[0].method, "POST");
    assert.equal(received[0].type, "application/json");
    assert.equal(
      received[0].body,
      '{"platform":"node","key":"k","app":{"id":"com.acme.app"},' +
        '"sdk":{"name":"tongue-js","version":"9.9.9"},' +
        '"sentAt":"2023-11-14T22:13:20.000Z",' +
        '"events":[{"name":"load","deviceId":"d","callCount":2}]}',
    );
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
