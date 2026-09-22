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
      send: (body) => {
        sends.push(body);
      },
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
    send: (body) => {
      sends.push(body);
    },
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

test("a forced load posts inside the window and resolves only once the send has", async () => {
  // `flushTelemetry()` is what a short-lived worker calls before it exits. Two
  // things have to hold for it to be worth calling: it posts although the window
  // has not elapsed, and it does not resolve before the POST does. An injected send
  // whose completion the test controls settles both.
  let state = { lastActiveAt: 0, carryCallCount: 0 };
  const now = 1700000000000;
  const sends = [];
  let release;
  const client = new UsageClient({
    deviceId: "d",
    platform: "node",
    version: "0.0.0",
    windowMs: vectors.windowMs,
    now: () => now,
    loadState: () => state,
    saveState: (next) => {
      state = next;
    },
    send: (body) => {
      sends.push(body);
      return new Promise((resolve) => {
        release = resolve;
      });
    },
  });

  client.start();
  client.flush();
  client.recordCall(3);

  const forced = client.load(); // ignores the window, unlike flush()
  assert.equal(sends.length, 2, "the forced load did not post inside the window");

  let settled = false;
  void Promise.resolve(forced).then(() => {
    settled = true;
  });
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(settled, false, "load() resolved before the send did");
  release();
  await forced;
  assert.equal(sends[1].events[0].callCount, 3);
  assert.equal(state.lastActiveAt, now, "the forced load stamps the window");
});

test("a flush with nothing recorded reports success and sends nothing", async () => {
  // The suite runs with the kill switch on, so the turnstile is built by hand
  // here. A process that started but never detected must not be billed: core's
  // flush skips a client with no usage, and an idle process is the common case.
  const { UsageTurnstile } = await import("../dist/usage.js");
  const disabled = process.env.DAL_USAGE_DISABLED;
  delete process.env.DAL_USAGE_DISABLED;
  let fetched = false;
  const realFetch = globalThis.fetch;
  globalThis.fetch = () => {
    fetched = true;
    return Promise.resolve({ ok: true });
  };
  try {
    const values = new Map();
    const turnstile = UsageTurnstile.create("9.9.9", {
      get: (k) => values.get(k) ?? null,
      set: (k, v) => values.set(k, v),
    });
    assert.ok(turnstile, "the turnstile builds once the switch is off");
    assert.equal(await turnstile.flushTelemetry(), true);
    assert.equal(fetched, false, "an idle turnstile posted a load");
  } finally {
    globalThis.fetch = realFetch;
    if (disabled !== undefined) process.env.DAL_USAGE_DISABLED = disabled;
  }
});

test("a forced flush takes the pending debounce, and the turnstile still flushes later", async (t) => {
  // A forced flush and the debounce occupy the same slot: the flush must take the
  // timer's place rather than race it, and a detection recorded afterwards must
  // still be delivered. Both halves discriminate, and timers are mocked so the
  // deadlines are exact: a timer left behind sends the next detection a debounce
  // early, and a flag left set means `record()` never schedules again, so that
  // detection is never sent at all. The Kotlin twin is pinned to the same two.
  const { UsageTurnstile } = await import("../dist/usage.js");
  const disabled = process.env.DAL_USAGE_DISABLED;
  delete process.env.DAL_USAGE_DISABLED;
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const posts = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (_url, init) => {
    posts.push(JSON.parse(init.body));
    return Promise.resolve({ ok: true });
  };
  try {
    const values = new Map();
    const turnstile = UsageTurnstile.create("9.9.9", {
      get: (k) => values.get(k) ?? null,
      set: (k, v) => values.set(k, v),
    });
    turnstile.record(); // debounce A due at 3000
    assert.equal(posts.length, 0, "the debounce posted before its delay");

    t.mock.timers.tick(300);
    assert.equal(await turnstile.flushTelemetry(), true);
    assert.equal(posts.length, 1, "the forced flush did not post");

    t.mock.timers.tick(100);
    turnstile.record(); // debounce B due at 3400
    t.mock.timers.tick(2_700); // 3100: past A's deadline, before B's
    assert.equal(posts.length, 1, "the debounce the flush replaced posted on its own");

    t.mock.timers.tick(400); // 3500: past B
    assert.equal(posts.length, 2, "the turnstile stopped flushing after a forced flush");
  } finally {
    globalThis.fetch = realFetch;
    if (disabled !== undefined) process.env.DAL_USAGE_DISABLED = disabled;
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
    // Awaiting the returned promise is the contract `flushTelemetry()` rests on:
    // it resolves once the server has answered, not when the request is queued.
    await makeSend(`http://127.0.0.1:${port}/api/v1/ingest`)({
      platform: "node",
      key: "k",
      app: { id: "com.acme.app" },
      sdk: { name: "tongue-js", version: "9.9.9" },
      sentAt: "2023-11-14T22:13:20.000Z",
      events: [{ name: "load", deviceId: "d", callCount: 2 }],
    });

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
