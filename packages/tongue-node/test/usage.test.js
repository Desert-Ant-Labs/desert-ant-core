import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { UsageClient, UsageTurnstile, defaultPlatform, makeSend } from "../dist/usage.js";
import { Tongue } from "../dist/index.js";

/** The platform tags the ingest endpoint accepts; anything else is a 400. */
const acceptedPlatforms = ["ios", "android", "web", "server"];

// A test that builds a real turnstile and leaves a call unsent would otherwise
// post it to production on exit. Tests that need a server set their own.
process.env.DAL_INGEST_ENDPOINT ??= "http://127.0.0.1:9/ingest";

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

test("the platform tag is one the endpoint accepts", () => {
  // A tag outside the enum is a 400, which drops the event: the turnstile still
  // looks healthy and the device is simply never billed. This port sent "node"
  // until it was checked against the live enum.
  assert.ok(
    acceptedPlatforms.includes(defaultPlatform()),
    `the endpoint rejects platform ${defaultPlatform()}`,
  );
  assert.equal(defaultPlatform(), "server", "a Node process is a server");
});

test("the wire body matches core's field order and carries no text", () => {
  const sends = [];
  const client = new UsageClient({
    deviceId: "d",
    key: "k",
    keyInBody: true,
    appId: "com.acme.app",
    platform: "server",
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
    '{"platform":"server","key":"k","app":{"id":"com.acme.app"},' +
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
    platform: "server",
    keyInBody: true,
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

test("a forced flush awaits the send the debounce started", async (t) => {
  // A flush right after the debounce fired has nothing left to send, but the POST
  // the debounce started may still be in flight. `flushTelemetry()` must wait for
  // it too, or a process that exits next drops the event.
  const { UsageTurnstile } = await import("../dist/usage.js");
  const disabled = process.env.DAL_USAGE_DISABLED;
  delete process.env.DAL_USAGE_DISABLED;
  t.mock.timers.enable({ apis: ["setTimeout"] });
  let answer;
  let posts = 0;
  const realFetch = globalThis.fetch;
  globalThis.fetch = () => {
    posts += 1;
    return new Promise((resolve) => (answer = () => resolve({ ok: true })));
  };
  try {
    const values = new Map();
    const turnstile = UsageTurnstile.create("9.9.9", {
      get: (k) => values.get(k) ?? null,
      set: (k, v) => values.set(k, v),
    });
    turnstile.record();
    t.mock.timers.tick(3_000);
    assert.equal(posts, 1, "the debounce did not post");

    let settled = false;
    const flushed = turnstile.flushTelemetry().then((ok) => {
      settled = true;
      return ok;
    });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(settled, false, "flushTelemetry resolved before the debounced POST was answered");
    answer();
    assert.equal(await flushed, true);
    assert.equal(posts, 1, "the forced flush posted a second load");
  } finally {
    globalThis.fetch = realFetch;
    if (disabled !== undefined) process.env.DAL_USAGE_DISABLED = disabled;
  }
});

test("a forced flush awaits every debounced send still in flight, not only the newest", async (t) => {
  // Fetches run concurrently, so on a slow endpoint the first debounce's POST can
  // still be pending when the second debounce fires. Keeping only the newest let
  // flushTelemetry() resolve with the first one, often the day's load, unsent.
  const { UsageTurnstile } = await import("../dist/usage.js");
  const disabled = process.env.DAL_USAGE_DISABLED;
  delete process.env.DAL_USAGE_DISABLED;
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const answers = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = () => new Promise((resolve) => answers.push(() => resolve({ ok: true })));
  try {
    const values = new Map();
    const turnstile = UsageTurnstile.create("9.9.9", {
      get: (k) => values.get(k) ?? null,
      set: (k, v) => values.set(k, v),
    });
    turnstile.record();
    t.mock.timers.tick(3_000);
    turnstile.record();
    t.mock.timers.tick(3_000);
    assert.equal(answers.length, 2, "both debounces should have posted");

    let settled = false;
    const flushed = turnstile.flushTelemetry().then((ok) => {
      settled = true;
      return ok;
    });
    answers[1]();
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(settled, false, "flushTelemetry resolved while the first POST was still pending");
    answers[0]();
    assert.equal(await flushed, true);
  } finally {
    globalThis.fetch = realFetch;
    if (disabled !== undefined) process.env.DAL_USAGE_DISABLED = disabled;
  }
});

test("a send is bounded, and a timed-out one is not sent again by beacon", async () => {
  // An endpoint that accepts and never answers must not hold flushTelemetry(),
  // and a process's exit, for minutes. A timeout may already have landed, so the
  // beacon fallback must not post it a second time.
  const { makeSend } = await import("../dist/usage.js");
  const realFetch = globalThis.fetch;
  const navigator = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  let signal;
  let beacons = 0;
  globalThis.fetch = (_url, init) => {
    signal = init.signal;
    const error = new Error("timed out");
    error.name = "TimeoutError";
    return Promise.reject(error);
  };
  Object.defineProperty(globalThis, "navigator", {
    value: { sendBeacon: () => (beacons += 1, true) },
    configurable: true,
  });
  try {
    await makeSend("http://127.0.0.1:9/ingest")({ events: [] });
    assert.ok(signal instanceof AbortSignal, "the POST carried no timeout signal");
    assert.equal(beacons, 0, "a timed-out POST was sent again by beacon");
  } finally {
    globalThis.fetch = realFetch;
    if (navigator) Object.defineProperty(globalThis, "navigator", navigator);
    else delete globalThis.navigator;
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
      received.push({
        method: req.method,
        type: req.headers["content-type"],
        auth: req.headers["authorization"],
        body,
      });
      res.writeHead(204).end();
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();

  try {
    // Awaiting the returned promise is the contract `flushTelemetry()` rests on:
    // it resolves once the server has answered, not when the request is queued.
    // The key goes in the header, so the body built here must not carry one.
    await makeSend(`http://127.0.0.1:${port}/api/v1/ingest`, "dal_test")({
      platform: "server",
      app: { id: "com.acme.app" },
      sdk: { name: "tongue-js", version: "9.9.9" },
      sentAt: "2023-11-14T22:13:20.000Z",
      events: [{ name: "load", deviceId: "d", callCount: 2 }],
    });

    assert.equal(received.length, 1, "the transport never reached the server");
    assert.equal(received[0].method, "POST");
    assert.equal(received[0].type, "application/json");
    assert.equal(received[0].auth, "Bearer dal_test", "the key did not ride the header");
    assert.equal(
      received[0].body,
      '{"platform":"server","app":{"id":"com.acme.app"},' +
        '"sdk":{"name":"tongue-js","version":"9.9.9"},' +
        '"sentAt":"2023-11-14T22:13:20.000Z",' +
        '"events":[{"name":"load","deviceId":"d","callCount":2}]}',
    );
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test("the turnstile a host builds puts the key in exactly one place", async () => {
  // The layer that decides the platform tag and the key's placement had no test:
  // every other case builds `UsageClient` literals with `send` already injected,
  // so a wrong `keyInBody` or a hardcoded platform tag survived the whole suite.
  // This constructs the turnstile the way a host does and reads what went on the
  // wire, with the endpoint pointed at a local server.
  const { createServer } = await import("node:http");
  const received = [];
  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      received.push({ auth: req.headers["authorization"], body });
      res.writeHead(202).end();
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();

  const saved = {
    DAL_USAGE_DISABLED: process.env.DAL_USAGE_DISABLED,
    DAL_INGEST_ENDPOINT: process.env.DAL_INGEST_ENDPOINT,
    DAL_API_KEY: process.env.DAL_API_KEY,
    DAL_DEVICE_ID: process.env.DAL_DEVICE_ID,
  };
  // `mise run test:node` sets DAL_USAGE_DISABLED=1 for every task, and create()
  // returns null when reporting is off.
  delete process.env.DAL_USAGE_DISABLED;
  process.env.DAL_INGEST_ENDPOINT = `http://127.0.0.1:${port}/api/v1/ingest`;
  process.env.DAL_API_KEY = "dal_test";
  process.env.DAL_DEVICE_ID = "e2e-host-device";

  try {
    const turnstile = UsageTurnstile.create("9.9.9");
    assert.ok(turnstile, "create() returned null with reporting enabled");
    turnstile.record();
    assert.equal(await turnstile.flushTelemetry(), true);

    assert.equal(received.length, 1, "the client never reached the server");
    assert.equal(received[0].auth, "Bearer dal_test", "the key did not ride the header");
    const sent = JSON.parse(received[0].body);
    assert.equal(
      acceptedPlatforms.includes(sent.platform),
      true,
      `the endpoint rejects platform ${sent.platform}`,
    );
    assert.equal(sent.platform, "server", "a Node process is a server");
    assert.equal(sent.key, undefined, "the key rode the body as well as the header");
  } finally {
    for (const [name, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
    await new Promise((resolve) => server.close(resolve));
  }
});

test("a flush awaits a send an earlier, unawaited flush started", async () => {
  // `void t.flushTelemetry(); await t.flushTelemetry()` used to resolve at once:
  // the second flush had nothing to send and did not know about the first POST.
  const { UsageTurnstile } = await import("../dist/usage.js");
  const disabled = process.env.DAL_USAGE_DISABLED;
  delete process.env.DAL_USAGE_DISABLED;
  let answer;
  const realFetch = globalThis.fetch;
  globalThis.fetch = () => new Promise((resolve) => (answer = () => resolve({ ok: true })));
  try {
    const values = new Map();
    const turnstile = UsageTurnstile.create("9.9.9", {
      get: (k) => values.get(k) ?? null,
      set: (k, v) => values.set(k, v),
    });
    turnstile.record();
    void turnstile.flushTelemetry();
    let settled = false;
    const second = turnstile.flushTelemetry().then((ok) => {
      settled = true;
      return ok;
    });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(settled, false, "the second flush resolved before the first flush's POST was answered");
    answer();
    assert.equal(await second, true);
  } finally {
    globalThis.fetch = realFetch;
    if (disabled !== undefined) process.env.DAL_USAGE_DISABLED = disabled;
  }
});

test("a worker in a server runtime is a server, not a page", () => {
  // Deno, Bun and Node workers expose worker globals too, but have no Origin: as
  // `web` with no key and no app id the endpoint answers 400.
  const had = "importScripts" in globalThis;
  globalThis.importScripts = () => {};
  try {
    assert.equal(defaultPlatform(), "server");
  } finally {
    if (!had) delete globalThis.importScripts;
  }
});

test("a key with surrounding whitespace is trimmed before it reaches the header", async () => {
  const { UsageTurnstile } = await import("../dist/usage.js");
  const saved = { disabled: process.env.DAL_USAGE_DISABLED, key: process.env.DAL_API_KEY };
  delete process.env.DAL_USAGE_DISABLED;
  process.env.DAL_API_KEY = "dal_test\n";
  const seen = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (_url, init) => {
    seen.push(init.headers.Authorization);
    return Promise.resolve({ ok: true });
  };
  try {
    const values = new Map();
    const turnstile = UsageTurnstile.create("9.9.9", {
      get: (k) => values.get(k) ?? null,
      set: (k, v) => values.set(k, v),
    });
    turnstile.record();
    await turnstile.flushTelemetry();
    assert.deepEqual(seen, ["Bearer dal_test"]);
  } finally {
    globalThis.fetch = realFetch;
    if (saved.disabled !== undefined) process.env.DAL_USAGE_DISABLED = saved.disabled;
    if (saved.key === undefined) delete process.env.DAL_API_KEY;
    else process.env.DAL_API_KEY = saved.key;
  }
});
