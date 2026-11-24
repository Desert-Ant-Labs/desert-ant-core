// The device license client alone, with its clock, timers and requests replaced, so nothing here waits or sends.
import { test } from "node:test";
import assert from "node:assert/strict";

import { DeviceLicenseClient } from "../dist/license.js";
import { signedToken, tamperedToken, testKey } from "./tokens.js";

process.env.DAL_LICENSE_ENDPOINT ||= "http://127.0.0.1:9/api/v1";
process.env.DAL_STATE_DIR ||= new URL("../node_modules/.cache/tongue-test", import.meta.url).pathname;

const SECOND = 1000;
const MINUTE = 60 * SECOND;
const HOUR = 60 * MINUTE;
const turn = () => new Promise((resolve) => setImmediate(resolve));
const json = (status, body, retryAfter = null) => ({ status, retryAfter, body: JSON.stringify(body) });

function harness({ apiKey = "dal_server_key", ...settings } = {}) {
  const h = {
    clock: 1_800_000_000_000,
    timers: [],
    posts: [],
    logs: [],
    reply: (path, payload) => h.granted(path, payload),
    granted(path, payload) {
      const serverTime = new Date(h.clock).toISOString();
      if (path === "license") return json(200, { token: signedToken(h.clock), serverTime });
      return json(200, { serverTime, results: payload.items.map(() => ({ token: signedToken(h.clock) })) });
    },
    paths: () => h.posts.map((one) => one.path),
    async settle() {
      for (let turns = 0; turns < 200; turns += 1) {
        await turn();
        if (!h.client.isSending) break;
      }
      await turn();
    },
    async advance(ms) {
      h.clock += ms;
      while (true) {
        const due = h.timers.filter((timer) => timer.due <= h.clock).sort((a, b) => a.due - b.due)[0];
        if (!due) break;
        h.timers.splice(h.timers.indexOf(due), 1);
        due.work();
        await h.settle();
      }
      await h.settle();
    },
    license(...ids) {
      for (const id of ids) if (h.client.begin(id)) h.client.license(id);
    },
  };
  h.client = new DeviceLicenseClient({
    now: () => h.clock,
    schedule: (delay, work) => h.timers.push({ due: h.clock + delay, delay, work }),
    jitter: (ceiling) => ceiling,
    identity: () => ({ appId: "acme-api", apiKey, platform: "server", namespace: apiKey ?? "acme-api" }),
    secret: () => "0123456789abcdef0123456789abcdef",
    installId: async (deviceId) => `install-${deviceId}`,
    publicKeys: { [testKey.kid]: testKey.publicKeyX963 },
    log: (level, message) => h.logs.push({ level, message }),
    post: async (path, payload) => {
      h.posts.push({ path, payload, at: h.clock });
      return h.reply(path, payload);
    },
    ...settings,
  });
  return h;
}

const ids = (count, prefix = "device") => Array.from({ length: count }, (_, index) => `${prefix}-${index}`);

test("fewer than 100 devices go together 10 seconds after the first", async () => {
  const h = harness();
  h.license("a", "b");
  await h.advance(4 * SECOND);
  h.license("c", "a");
  await h.advance(6 * SECOND - 1);
  assert.deepEqual(h.posts, []);
  await h.advance(1);
  assert.equal(h.posts.length, 1);
  assert.deepEqual(h.posts[0].path, "licenses");
  assert.deepEqual(h.posts[0].payload, {
    sdk: h.posts[0].payload.sdk,
    platform: "server",
    app: { id: "acme-api" },
    key: "dal_server_key",
    items: ["a", "b", "c"].map((id) => ({ installId: `install-${id}`, model: "tongue", modelVersion: h.posts[0].payload.items[0].modelVersion })),
  });
  assert.equal(h.client.waiting, 0);
  assert.equal(h.timers.length, 0);

  h.license("a", "b", "c");
  await h.advance(HOUR);
  assert.equal(h.posts.length, 1, "a device with a license asked again");
});

test("250 devices in a burst make batches of 100, 100 and 50, and no single request", async () => {
  const h = harness();
  h.license(...ids(250));
  await h.settle();
  assert.deepEqual(h.posts.map((one) => one.payload.items.length), [100, 100]);
  await h.advance(10 * SECOND);
  assert.deepEqual(h.paths(), ["licenses", "licenses", "licenses"]);
  assert.deepEqual(h.posts.map((one) => one.payload.items.length), [100, 100, 50]);
  assert.equal(new Set(h.posts.flatMap((one) => one.payload.items.map((item) => item.installId))).size, 250);
});

test("while a request is on its way, new devices wait for the next one, and a timer that fires meanwhile loses nothing", async () => {
  const h = harness();
  let answer;
  h.reply = (path, payload) => (h.posts.length === 1 ? new Promise((resolve) => (answer = () => resolve(h.granted(path, payload)))) : h.granted(path, payload));
  h.license("a");
  await h.advance(10 * SECOND);
  assert.equal(h.posts.length, 1);
  assert.equal(h.client.isSending, true);

  h.license("b");
  await h.advance(10 * SECOND);
  assert.equal(h.posts.length, 1, "a second request started while the first was on its way");
  assert.equal(h.timers.length, 0);

  answer();
  await h.settle();
  assert.deepEqual(h.posts.map((one) => one.payload.items.map((item) => item.installId)), [["install-a"], ["install-b"]]);
  assert.equal(h.client.waiting, 0);
});

test("a batch the server turns down with 404 becomes single grants for an hour, then the batch is tried again", async () => {
  const h = harness();
  h.reply = (path, payload) => (path === "licenses" ? json(404, { error: "not_found" }) : h.granted(path, payload));
  h.license("a", "b");
  await h.advance(10 * SECOND);
  assert.deepEqual(h.paths(), ["licenses", "license", "license"]);
  assert.deepEqual(h.posts.slice(1).map((one) => one.payload.installId), ["install-a", "install-b"]);
  assert.equal(h.posts[1].payload.key, "dal_server_key");
  assert.deepEqual(h.logs.map((one) => one.level), ["info"]);
  assert.match(h.logs[0].message, /did not accept a batch \(HTTP 404\)/);

  h.license("c");
  await h.advance(10 * SECOND);
  assert.deepEqual(h.paths().slice(3), ["license"]);

  await h.advance(HOUR - 30 * SECOND - 1);
  h.license("d");
  await h.advance(10 * SECOND);
  assert.deepEqual(h.paths().slice(4), ["license"], "the batch was tried again before the hour ended");

  h.license("e");
  await h.advance(10 * SECOND + 1);
  assert.deepEqual(h.paths().slice(5), ["licenses", "license"]);
  assert.equal(h.logs.length, 1);
  assert.equal(h.client.waiting, 0);
});

test("a batch refused with 400 is a warning, and with no API key every device is one request", async () => {
  const refused = harness();
  refused.reply = (path, payload) => (path === "licenses" ? json(400, { error: "invalid_key" }) : refused.granted(path, payload));
  refused.license("a");
  await refused.advance(10 * SECOND);
  assert.deepEqual(refused.paths(), ["licenses", "license"]);
  assert.deepEqual(refused.logs.map((one) => one.level), ["warning"]);

  const keyless = harness({ apiKey: null });
  keyless.license("a", "b");
  await keyless.advance(10 * SECOND);
  assert.deepEqual(keyless.paths(), ["license", "license"]);
  assert.equal("key" in keyless.posts[0].payload, false);
});

test("in a batch answer, an item with no token or a bad signature is held for a day, and the others until they expire", async () => {
  const h = harness();
  h.reply = () => json(200, {
    serverTime: new Date(h.clock).toISOString(),
    results: [{ token: signedToken(h.clock) }, {}, { token: tamperedToken(h.clock) }, { token: null }],
  });
  h.license("valid", "missing", "tampered", "null");
  await h.advance(10 * SECOND);
  assert.equal(h.posts.length, 1);
  assert.equal(h.client.waiting, 0);

  await h.advance(24 * HOUR - MINUTE);
  for (const id of ["valid", "missing", "tampered", "null"]) assert.equal(h.client.begin(id), false, id);
  await h.advance(MINUTE);
  assert.equal(h.client.begin("valid"), false);
  for (const id of ["missing", "tampered", "null"]) assert.equal(h.client.begin(id), true, id);
  await h.advance(29 * 24 * HOUR);
  assert.equal(h.client.begin("valid"), true);
});

test("a batch answer with the wrong number of results is sent again after the backoff", async () => {
  const h = harness();
  h.reply = () => json(200, { results: [{}] });
  h.license("a", "b");
  await h.advance(10 * SECOND);
  assert.equal(h.posts.length, 1);
  assert.equal(h.client.waiting, 2);
  assert.deepEqual(h.timers.map((timer) => timer.delay), [MINUTE]);
  assert.match(h.logs[0].message, /an answer the SDK cannot read/);
});

test("a round that fails counts as one attempt of the backoff, and a success starts it again", async () => {
  const h = harness();
  h.reply = () => json(503, { error: "retry" });
  h.license(...ids(4));
  await h.advance(10 * SECOND);
  const waits = [];
  for (let round = 0; round < 3; round += 1) {
    assert.equal(h.posts.length, round + 1);
    assert.equal(h.timers.length, 1);
    waits.push(h.timers[0].delay);
    await h.advance(h.timers[0].delay);
  }
  assert.deepEqual(waits, [MINUTE, 2 * MINUTE, 4 * MINUTE]);
  assert.equal(h.logs.length, 1);

  h.reply = h.granted;
  await h.advance(8 * MINUTE);
  assert.equal(h.client.waiting, 0);
  h.reply = () => json(503, { error: "retry" });
  h.license("later");
  await h.advance(10 * SECOND);
  assert.deepEqual(h.timers.map((timer) => timer.delay), [MINUTE]);

  const single = harness({ apiKey: null });
  single.reply = () => json(503, { error: "retry" });
  single.license(...ids(4));
  await single.advance(10 * SECOND);
  assert.equal(single.posts.length, 1);
  assert.deepEqual(single.timers.map((timer) => timer.delay), [MINUTE]);
  await single.advance(MINUTE);
  assert.equal(single.posts.length, 2);
  assert.deepEqual(single.timers.map((timer) => timer.delay), [2 * MINUTE]);
});

test("a connection that fails never shortens a wait the server asked for", async () => {
  const h = harness();
  h.reply = () => null;
  h.license("a");
  await h.advance(10 * SECOND);
  assert.deepEqual(h.timers.map((timer) => timer.delay), [5 * MINUTE]);

  h.reply = () => json(429, { error: "slow_down" }, "3600");
  assert.equal(await h.client.flush(), false);
  assert.equal(h.posts.length, 2);
  const asked = h.clock;

  h.reply = () => null;
  h.license("b");
  assert.equal(await h.client.flush(), false);
  await h.advance(5 * MINUTE);
  assert.equal(await h.client.flush(), false);
  await h.advance(HOUR - 5 * MINUTE - 1);
  assert.equal(h.posts.length, 2, "a request went out before the hour the server asked for");

  await h.advance(1);
  assert.equal(h.posts.length, 3);
  assert.equal(h.posts[2].at, asked + HOUR);
  assert.equal(await h.client.flush(), false);
  assert.equal(h.posts.length, 4, "a flush did not send before the network retry was due");
});

test("a flush sends a partial batch at once, and resolves false when devices are left", async () => {
  const h = harness();
  h.license("a", "b", "c");
  assert.equal(await h.client.flush(), true);
  assert.deepEqual(h.posts.map((one) => one.payload.items.length), [3]);
  assert.equal(h.posts[0].at, h.clock);
  await h.advance(HOUR);
  assert.equal(h.posts.length, 1);

  h.reply = () => json(503, { error: "retry" }, "120");
  h.license("d");
  assert.equal(await h.client.flush(), false);
  assert.equal(await h.client.flush(), false);
  assert.equal(h.posts.length, 2);
});

test("a flush starts no request after its 10 seconds, and the timer sends the rest", async () => {
  const h = harness({ apiKey: null });
  h.reply = (path, payload) => {
    h.clock += 4 * SECOND;
    return h.granted(path, payload);
  };
  h.license(...ids(5));
  assert.equal(await h.client.flush(), false);
  assert.equal(h.posts.length, 3);
  assert.equal(h.client.waiting, 2);
  assert.equal(h.timers.length, 1);
  await h.advance(10 * SECOND);
  assert.equal(h.posts.length, 5);
  assert.equal(h.client.waiting, 0);
});

test("two flushes at once both resolve, and send each device once", async () => {
  const h = harness();
  h.license(...ids(150));
  await turn();
  const results = await Promise.all([h.client.flush(), h.client.flush(), h.client.flush()]);
  assert.deepEqual(results, [true, true, true]);
  assert.deepEqual(h.posts.map((one) => one.payload.items.length), [100, 50]);
});

test("a full queue leaves new devices out with one warning, and they ask again later", async () => {
  const h = harness({ queueLimit: 3 });
  h.reply = () => null;
  h.license("a", "b", "c", "d", "e");
  assert.equal(h.client.waiting, 3);
  assert.equal(h.logs.length, 1);
  assert.match(h.logs[0].message, /The license queue is full \(3 devices wait\)/);

  h.reply = h.granted;
  assert.equal(await h.client.flush(), true);
  await h.advance(MINUTE);
  h.license("d", "e");
  assert.equal(await h.client.flush(), true);
  assert.deepEqual(h.posts.at(-1).payload.items.map((item) => item.installId), ["install-d", "install-e"]);
});

test("the device memory is capped: a full map forgets devices, and never grows past its capacity", async () => {
  const h = harness({ capacity: 10 });
  h.license(...ids(25));
  assert.equal(await h.client.flush(), true);
  assert.equal(new Set(h.posts.flatMap((one) => one.payload.items.map((item) => item.installId))).size, 25);
  const held = ids(25).filter((id) => !h.client.begin(id)).length;
  assert.ok(held <= 10, String(held));
});

function random(seed) {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 2 ** 32;
  };
}

test("random answers, timers and overlapping flushes never stall the queue or hang a flush", async () => {
  for (let seed = 1; seed <= 150; seed += 1) {
    const next = random(seed);
    const pick = (list) => list[Math.floor(next() * list.length)];
    const h = harness({ apiKey: seed % 3 === 0 ? null : "dal_server_key", jitter: (ceiling) => Math.floor(next() * (ceiling + 1)), batchItems: 5, queueLimit: 40 });
    const hanging = [];
    const flushes = [];
    let calm = false;
    const answer = (path, payload) => {
      const kind = calm ? "ok" : pick(["ok", "ok", "ok", "unavailable", "slow-down", "refused", "missing", "no-answer", "garbage"]);
      if (kind === "ok") return h.granted(path, payload);
      if (kind === "unavailable") return json(503, { error: "retry" });
      if (kind === "slow-down") return json(429, { error: "slow_down" }, String(Math.floor(next() * 7200)));
      if (kind === "refused") return json(400, { error: "invalid_request" });
      if (kind === "missing") return json(404, { error: "not_found" });
      if (kind === "garbage") return { status: 200, retryAfter: null, body: "<html>" };
      return null;
    };
    h.reply = (path, payload) => {
      if (calm || next() > 0.2) return answer(path, payload);
      return new Promise((resolve) => hanging.push(() => resolve(answer(path, payload))));
    };
    const stalled = () => h.client.waiting > 0 && !h.client.isSending && !h.client.hasTimer;
    let made = 0;
    for (let step = 0; step < 60; step += 1) {
      const roll = next();
      if (roll < 0.4) h.license(...Array.from({ length: 1 + Math.floor(next() * 8) }, () => `device-${next() < 0.2 ? Math.floor(next() * (made + 1)) : (made += 1)}`));
      else if (roll < 0.65) await h.advance(Math.floor(next() * 15 * SECOND));
      else if (roll < 0.8) {
        const flush = { done: false };
        h.client.flush().then((result) => Object.assign(flush, { done: true, result }));
        flushes.push(flush);
      } else if (roll < 0.95) hanging.splice(Math.floor(next() * hanging.length), 1)[0]?.();
      else await h.advance(pick([MINUTE, HOUR, 7 * HOUR]));
      await turn();
      await turn();
      assert.equal(stalled(), false, `seed ${seed}, step ${step}: devices wait with no request and no timer`);
    }

    calm = true;
    for (let round = 0; round < 40 && (h.client.waiting > 0 || hanging.length > 0 || h.client.isSending); round += 1) {
      for (const release of hanging.splice(0)) release();
      await h.settle();
      await h.advance(7 * HOUR);
    }
    assert.equal(h.client.waiting, 0, `seed ${seed}: ${h.client.waiting} devices never got a request`);
    assert.equal(h.client.isSending, false, `seed ${seed}`);
    await h.settle();
    assert.deepEqual(flushes.filter((flush) => !flush.done), [], `seed ${seed}: a flush never resolved`);
    assert.equal(await h.client.flush(), true, `seed ${seed}`);
  }
});
