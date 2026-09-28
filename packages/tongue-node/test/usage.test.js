import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { UsageClient, UsageTurnstile, defaultPlatform, makeSend } from "../dist/usage.js";
import { Tongue } from "../dist/index.js";

/** The platform tags the ingest endpoint accepts; anything else is a 400. */
const acceptedPlatforms = ["ios", "android", "web", "server"];

// Replays the shared turnstile contract. The Kotlin port replays the identical
// file against its own hand-ported client; the Swift SDK uses desert-ant-core's
// client directly, which is where this behaviour comes from. See docs/USAGE.md.
const here = dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(readFileSync(join(here, "usage_vectors.json"), "utf8"));

test("turnstile matches the shared contract", () => {
  for (const c of vectors.cases) {
    let state = { lastActiveAt: c.stateLastActiveAt, carryCallCount: c.stateCarry };
    if (c.stateEmitDay >= 0) state.lastEmitDay = c.stateEmitDay;
    let now = 0;
    const sends = [];

    const makeClient = () => new UsageClient({
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
    let client = makeClient();

    c.stepKinds.forEach((kind, i) => {
      now = c.stepAt[i];
      if (kind === "start") client.start();
      else if (kind === "flush") client.flush();
      else if (kind === "record") client.recordCall(c.stepN[i]);
      else if (kind === "suspend") client.suspend();
      else if (kind === "relaunch") client = makeClient();
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
    assert.equal(state.lastEmitDay ?? -1, c.finalEmitDay, `${c.name}: final emit day`);
  }
});

test("a storage global that throws on read falls back to memory", () => {
  // A child process: once Tongue.load() installs its file store, the globals are never read.
  const script = fileURLToPath(new URL("./fixtures-throwing-storage.mjs", import.meta.url));
  const result = JSON.parse(execFileSync(process.execPath, [script], { encoding: "utf8" }));
  assert.equal(result.posts, 1, "a throwing storage getter stopped reporting");
});

test("a client build that fails once is tried again on the next detection", async () => {
  const posts = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (_url, init) => {
    posts.push(JSON.parse(init.body));
    return Promise.resolve({ ok: true });
  };
  const values = new Map();
  let failures = 1;
  const store = {
    get: (k) => {
      if (failures > 0) {
        failures -= 1;
        throw new Error("transient");
      }
      return values.get(k) ?? null;
    },
    set: (k, v) => values.set(k, v),
  };
  const exitHooks = process.listeners("beforeExit");
  try {
    const turnstile = UsageTurnstile.create("9.9.9", store);
    turnstile.record();
    assert.equal(await turnstile.flushTelemetry(), true);
    assert.equal(posts.length, 0, "the failed build reported");
    turnstile.record();
    assert.equal(await turnstile.flushTelemetry(), true);
    assert.equal(posts.length, 1, "one failed build stopped reporting for good");
  } finally {
    for (const hook of process.listeners("beforeExit")) {
      if (!exitHooks.includes(hook)) process.off("beforeExit", hook);
    }
    globalThis.fetch = realFetch;
  }
});

test("the platform tag is one the endpoint accepts", () => {
  // A tag outside the enum is a 400, which drops the event: the turnstile still
  // looks healthy and the device is never billed.
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

test("a detection always posts to the ingest", async () => {
  // Every detection reports, here to a local capture server.
  const { createServer } = await import("node:http");
  const posts = [];
  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      posts.push(JSON.parse(body));
      res.writeHead(202).end();
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const savedEndpoint = process.env.DAL_INGEST_ENDPOINT;
  process.env.DAL_INGEST_ENDPOINT = `http://127.0.0.1:${server.address().port}/api/v1/ingest`;
  const exitHooks = process.listeners("beforeExit");
  try {
    const tongue = await Tongue.load();
    assert.equal(tongue.detect("kann ich das haben").language, "de");
    assert.equal(await tongue.flushTelemetry(), true);
    assert.equal(posts.length, 1, "the detection did not report");
    assert.equal(posts[0].events[0].callCount, 1);
  } finally {
    for (const hook of process.listeners("beforeExit")) {
      if (!exitHooks.includes(hook)) process.off("beforeExit", hook);
    }
    if (savedEndpoint === undefined) delete process.env.DAL_INGEST_ENDPOINT;
    else process.env.DAL_INGEST_ENDPOINT = savedEndpoint;
    await new Promise((resolve) => server.close(resolve));
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
  // A process that started but never detected must not be billed: core's
  // flush skips a client with no usage, and an idle process is the common case.
  const { UsageTurnstile } = await import("../dist/usage.js");
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
    assert.ok(turnstile, "the turnstile did not build");
    assert.equal(await turnstile.flushTelemetry(), true);
    assert.equal(fetched, false, "an idle turnstile posted a load");
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("start() reads storage again only once a turnstile could be due", () => {
  // The turnstile calls start() on every detection, and Node's store reads a file.
  let state = { lastActiveAt: 0, carryCallCount: 0 };
  let reads = 0;
  let now = 1_700_000_000_000; // 22:13:20Z
  const sends = [];
  const client = new UsageClient({
    deviceId: "d",
    platform: "test",
    version: "0.0.0",
    windowMs: vectors.windowMs,
    now: () => now,
    loadState: () => {
      reads += 1;
      return state;
    },
    saveState: (next) => {
      state = next;
    },
    send: (body) => {
      sends.push(body);
    },
  });
  client.start();
  client.flush();
  const settled = reads;
  for (let i = 0; i < 100; i++) client.start();
  assert.equal(reads, settled, "a start inside the day read storage");

  now += 2 * 60 * 60 * 1000; // past UTC midnight
  client.start();
  client.flush();
  assert.equal(sends.length, 2, "the new UTC day opened no turnstile");
});

test("a wall clock stepped back past midnight still opens the day", () => {
  // A host whose clock ran a day fast and was then corrected: the gate set on the
  // fast clock must not hold start() shut until real time catches up.
  let now = 1_700_000_000_000 + 86_400_000; // a day fast
  let state = { lastActiveAt: 0, carryCallCount: 0 };
  const sends = [];
  const client = new UsageClient({
    deviceId: "d",
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
  client.start();
  client.flush();
  now -= 86_400_000; // corrected, back onto the previous UTC day
  client.start();
  client.flush();
  assert.equal(sends.length, 2, "the corrected day opened no turnstile");
});

test("in a 30-minute window, start() reads storage again once the window can have passed", () => {
  // The day never bounds this gate here; the window does, from both branches.
  const windowMs = 30 * 60 * 1000;
  let now = 1_700_000_000_000 - 12 * 60 * 60 * 1000; // mid-day UTC
  let reads = 0;
  const sends = [];
  const make = (state) => {
    const client = new UsageClient({
      deviceId: "d",
      platform: "test",
      version: "0.0.0",
      windowMs,
      now: () => now,
      loadState: () => {
        reads += 1;
        return state;
      },
      saveState: (next) => {
        state = next;
      },
      send: (body) => {
        sends.push(body);
      },
    });
    return client;
  };

  // After an emit: skipped until the window has run from it, then a new one.
  const emitting = make({ lastActiveAt: 0, carryCallCount: 0 });
  emitting.start();
  emitting.flush();
  let settled = reads;
  now += windowMs - 1;
  emitting.start();
  assert.equal(reads, settled, "a start inside the window read storage");
  now += 1;
  emitting.start();
  emitting.flush();
  assert.equal(sends.length, 2, "the elapsed window opened no turnstile");

  // After a skip: the gate is the stored lastActiveAt plus the window.
  sends.length = 0;
  const day = Math.floor(now / 86_400_000);
  const skipping = make({ lastActiveAt: now - 10 * 60 * 1000, carryCallCount: 0, lastEmitDay: day });
  skipping.start();
  settled = reads;
  now += 20 * 60 * 1000 - 1;
  skipping.start();
  assert.equal(reads, settled, "a start inside the stored window read storage");
  now += 1;
  skipping.start();
  skipping.flush();
  assert.equal(sends.length, 1, "the elapsed stored window opened no turnstile");
});

test("state stored before the emit day existed emits on the next start, and keeps its two-field shape", async (t) => {
  // Core and the Kotlin port read the same keys and reset a `.state` that is not
  // exactly two fields, so the day rides a key of its own. State an older release
  // wrote has none, and the first start after the upgrade must emit, even inside
  // the window, or a device used every day is never billed again. Through the
  // debounce, not flushTelemetry(): a forced flush emits whatever start() decided.
  const { UsageTurnstile } = await import("../dist/usage.js");
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: 1_700_000_000_000 });
  // Each client this opens adds an exit hook; removed after, so the file's
  // turnstiles stay under Node's listener warning.
  const exitHooks = process.listeners("beforeExit");
  const posts = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (_url, init) => {
    posts.push(JSON.parse(init.body));
    return Promise.resolve({ ok: true });
  };
  try {
    const values = new Map();
    const store = { get: (k) => values.get(k) ?? null, set: (k, v) => values.set(k, v) };
    // The client opens on the first detection.
    UsageTurnstile.create("9.9.9", store).record();
    t.mock.timers.tick(3_000);
    assert.equal(posts.length, 1);
    const stateKey = [...values.keys()].find((k) => k.endsWith(".state"));
    const emitDayKey = stateKey.replace(/\.state$/, ".emitDay");
    assert.equal(values.get(emitDayKey), "19675");

    values.delete(emitDayKey);
    values.set(stateKey, `${Date.now()},2`);
    const upgraded = UsageTurnstile.create("9.9.9", store);
    upgraded.record();
    t.mock.timers.tick(3_000);
    assert.equal(posts.length, 2, "the upgraded start opened no turnstile");
    assert.equal(posts[1].events[0].callCount, 3, "the carried calls rode the turnstile");
    assert.match(values.get(stateKey), /^\d+,0$/);
    assert.equal(values.get(emitDayKey), "19675");
  } finally {
    for (const hook of process.listeners("beforeExit")) {
      if (!exitHooks.includes(hook)) process.off("beforeExit", hook);
    }
    globalThis.fetch = realFetch;
  }
});

test("a turnstile created on a day that already posted emits on its first detection of the next day", async (t) => {
  // start() used to run only when the client opened, on the first detection, so
  // one opened inside the window (a server redeployed the same day) carried every
  // call for as long as it lived.
  const { UsageTurnstile } = await import("../dist/usage.js");
  // 2023-11-14T22:13:20Z, two hours before a UTC midnight.
  t.mock.timers.enable({ apis: ["setTimeout", "Date"], now: 1_700_000_000_000 });
  // Each client this opens adds an exit hook; removed after, so the file's
  // turnstiles stay under Node's listener warning.
  const exitHooks = process.listeners("beforeExit");
  const posts = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (_url, init) => {
    posts.push(JSON.parse(init.body));
    return Promise.resolve({ ok: true });
  };
  try {
    const values = new Map();
    const store = { get: (k) => values.get(k) ?? null, set: (k, v) => values.set(k, v) };
    const first = UsageTurnstile.create("9.9.9", store);
    first.record();
    t.mock.timers.tick(3_000);
    assert.equal(posts.length, 1);

    const redeployed = UsageTurnstile.create("9.9.9", store);
    redeployed.record();
    t.mock.timers.tick(3_000);
    assert.equal(posts.length, 1, "a second turnstile the same day posted");

    t.mock.timers.tick(2 * 60 * 60 * 1000);
    redeployed.record();
    t.mock.timers.tick(3_000);
    assert.equal(posts.length, 2, "the new UTC day opened no turnstile");
    assert.equal(posts[1].events[0].callCount, 2, "the carried call rode the turnstile");
  } finally {
    for (const hook of process.listeners("beforeExit")) {
      if (!exitHooks.includes(hook)) process.off("beforeExit", hook);
    }
    globalThis.fetch = realFetch;
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
  }
});

test("a forced flush awaits the send the debounce started", async (t) => {
  // A flush right after the debounce fired has nothing left to send, but the POST
  // the debounce started may still be in flight. `flushTelemetry()` must wait for
  // it too, or a process that exits next drops the event.
  const { UsageTurnstile } = await import("../dist/usage.js");
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
  }
});

test("a forced flush awaits every debounced send still in flight, not only the newest", async (t) => {
  // Fetches run concurrently, so on a slow endpoint the first debounce's POST can
  // still be pending when the second debounce fires. Keeping only the newest
  // would let flushTelemetry() resolve with the first one, often the day's load,
  // unsent.
  const { UsageTurnstile } = await import("../dist/usage.js");
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
  // Everything else about the turnstile is tested with an injected `send`; this
  // drives the real transport at a local server. The destination stays
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
  // Every other case builds `UsageClient` literals with `send` already injected,
  // so a wrong `keyInBody` or a hardcoded platform tag would survive them. This
  // constructs the turnstile the way a host does and reads what went on the
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
    DAL_INGEST_ENDPOINT: process.env.DAL_INGEST_ENDPOINT,
    DAL_API_KEY: process.env.DAL_API_KEY,
    DAL_DEVICE_ID: process.env.DAL_DEVICE_ID,
  };
  process.env.DAL_INGEST_ENDPOINT = `http://127.0.0.1:${port}/api/v1/ingest`;
  process.env.DAL_API_KEY = "dal_test";
  process.env.DAL_DEVICE_ID = "e2e-host-device";

  try {
    const turnstile = UsageTurnstile.create("9.9.9");
    assert.ok(turnstile, "create() returned null");
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
  // `void t.flushTelemetry(); await t.flushTelemetry()`: the second flush has
  // nothing to send, but must still wait for the first POST.
  const { UsageTurnstile } = await import("../dist/usage.js");
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
  const saved = { key: process.env.DAL_API_KEY };
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
    if (saved.key === undefined) delete process.env.DAL_API_KEY;
    else process.env.DAL_API_KEY = saved.key;
  }
});
