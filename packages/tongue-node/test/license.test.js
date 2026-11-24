// Every case runs the package in a child process against a license server on 127.0.0.1, so each starts as a new process does.
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { deviceInstallId } from "../dist/license.js";
import { repo, signedToken, tamperedToken, testKey } from "./tokens.js";

process.env.DAL_LICENSE_ENDPOINT ||= "http://127.0.0.1:9/api/v1";
process.env.DAL_STATE_DIR ||= new URL("../node_modules/.cache/tongue-test", import.meta.url).pathname;

const sdkVersion = readFileSync(new URL("VERSION", repo), "utf8").trim();
const modelVersion = /revision = "([^"]+)"/.exec(readFileSync(new URL("Sources/Tongue/Catalog.swift", repo), "utf8"))[1];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SECRET = "0123456789abcdef0123456789abcdef";
const DEAD_ENDPOINT = "http://127.0.0.1:9/api/v1";
const DEVICE_IDS = ["device-1", "device-2", "device-3"];

const json = (status, body, headers = {}) => (res) => {
  res.writeHead(status, { "content-type": "application/json", ...headers });
  res.end(JSON.stringify(body));
};

// One license for `POST /license`, and one for each item of `POST /licenses`.
const granting = (token) => (res, route, body) => {
  const serverTime = new Date().toISOString();
  if (route === "license") return json(200, { token: token(), serverTime })(res);
  json(200, { serverTime, results: body.items.map(() => ({ token: token() })) })(res);
};

const modes = {
  grant: granting(signedToken),
  "tampered-token": granting(tamperedToken),
  "no-batch": (res, route, body) => (route === "licenses" ? json(404, { error: "not_found" })(res) : modes.grant(res, route, body)),
  refuse: json(400, { error: "invalid_request" }),
  unavailable: json(503, { error: "retry" }, { "retry-after": "3600" }),
  "captive-portal": (res) => {
    res.writeHead(200, { "content-type": "text/html" });
    res.end("<html>captive portal</html>");
  },
  silent: () => {},
};

const seen = {};
const server = http.createServer((req, res) => {
  const [, run, mode, ...rest] = req.url.split("/");
  let body = "";
  req.on("data", (chunk) => (body += chunk));
  req.on("end", () => {
    const request = { path: `/${rest.join("/")}`, method: req.method, headers: req.headers, body: JSON.parse(body) };
    (seen[run] ??= []).push(request);
    (modes[mode] ?? json(404, { error: "not_found" }))(res, rest.at(-1), request.body);
  });
});

let directory;
before(async () => {
  directory = mkdtempSync(join(tmpdir(), "tongue-license-"));
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
});
after(() => {
  server.closeAllConnections();
  server.close();
  rmSync(directory, { recursive: true, force: true });
});

const prelude = `
process.on("unhandledRejection", (error) => { console.error("UNHANDLED_REJECTION " + error); process.exitCode = 3; });
const say = (value) => console.log("RESULT " + JSON.stringify(value));
if (process.env.TEST_STORE) {
  const fs = await import("node:fs");
  const read = () => { try { return JSON.parse(fs.readFileSync(process.env.TEST_STORE, "utf8")); } catch { return {}; } };
  globalThis.__dalUsageStore = {
    getItem: (key) => read()[key] ?? null,
    setItem: (key, value) => fs.writeFileSync(process.env.TEST_STORE, JSON.stringify({ ...read(), [key]: value })),
  };
}
// As a copy of @desert-ant-labs/core loaded first leaves it, in its older shape with no flushes.
if (process.env.TEST_CORE_FIRST) {
  globalThis[Symbol.for("desert-ant-labs.configure")] = { settings: { apiKey: null, deviceIdSecret: null }, cores: new Set() };
}
const license = await import(${JSON.stringify(new URL("../dist/license.js", import.meta.url).href)});
license.licensePublicKeys[${JSON.stringify(testKey.kid)}] = ${JSON.stringify(testKey.publicKeyX963)};
const load = () => import(${JSON.stringify(new URL("../dist/index.js", import.meta.url).href)});
const TEXT = "kann ich das haben";
`;

// Each run keeps its state in a folder of its own unless a case passes one to share.
function runChild(script, { mode = "grant", endpoint, state, store, app, coreFirst } = {}) {
  const run = randomUUID();
  const appId = app ?? `ai.desertant.tongue.test.${run}`;
  const stateDir = state ?? mkdtempSync(join(directory, "state-"));
  return new Promise((resolve) => {
    const child = spawn(process.execPath, ["--input-type=module", "-e", prelude + script], {
      env: {
        ...process.env,
        DAL_LICENSE_ENDPOINT: endpoint ?? `http://127.0.0.1:${server.address().port}/${run}/${mode}/api/v1`,
        DAL_APP_ID: appId,
        DAL_STATE_DIR: stateDir,
        TEST_STORE: store ?? "",
        TEST_CORE_FIRST: coreFirst ? "1" : "",
      },
    });
    let stdout = "";
    let stderr = "";
    let resultAt = null;
    child.stdout.on("data", (chunk) => {
      if (resultAt === null && String(chunk).includes("RESULT ")) resultAt = performance.now();
    });
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    const timer = setTimeout(() => child.kill("SIGKILL"), 60_000);
    child.on("close", (code) => {
      clearTimeout(timer);
      const line = stdout.split("\n").find((one) => one.startsWith("RESULT "));
      resolve({
        code,
        stderr,
        appId,
        stateDir,
        exitAfterMs: resultAt === null ? null : performance.now() - resultAt,
        result: line ? JSON.parse(line.slice("RESULT ".length)) : null,
        requests: seen[run] ?? [],
      });
    });
  });
}

function assertClean(run) {
  assert.equal(run.code, 0, run.stderr);
  assert.ok(!run.stderr.includes("UNHANDLED_REJECTION"), run.stderr);
  assert.ok(run.result, `no result:\n${run.stderr}`);
}

const stateOf = (dir) => JSON.parse(readFileSync(join(dir, "tongue.json"), "utf8"));
const recordOf = (run) => JSON.parse(stateOf(run.stateDir)[`ai.desertant.tongue.license.${run.appId}`]);

const loadDetectFlush = `
const { Tongue } = await load();
const tongue = await Tongue.load();
const language = tongue.detect(TEXT).language;
const flushed = await tongue.flushLicenses();
await Tongue.load();
say({ language, flushed, again: await tongue.flushLicenses() });
`;

test("the first load asks for one license, with the key in the body", async () => {
  const run = await runChild(`
const { DesertAnt } = await load();
DesertAnt.configure({ apiKey: " dal_test_key\\n" });
${loadDetectFlush}`);
  assertClean(run);
  assert.deepEqual(run.result, { language: "de", flushed: true, again: true });
  assert.equal(run.requests.length, 1);
  const [request] = run.requests;
  assert.equal(request.path, "/api/v1/license");
  assert.equal(request.method, "POST");
  assert.equal(request.headers["content-type"], "application/json");
  assert.equal(request.headers.authorization, undefined);
  assert.match(request.body.installId, UUID);
  assert.deepEqual(request.body, {
    installId: request.body.installId,
    model: "tongue",
    modelVersion,
    sdk: { name: "desert-ant-core", version: sdkVersion },
    platform: "server",
    app: { id: run.appId },
    key: "dal_test_key",
  });
});

test("Node keeps the license in a state file, so a second process asks nothing and is the same install", async () => {
  const first = await runChild(loadDetectFlush);
  assertClean(first);
  assert.equal(first.requests.length, 1);
  assert.equal("key" in first.requests[0].body, false);

  const kept = stateOf(first.stateDir);
  assert.equal(kept["ai.desertant.usage.deviceId"], first.requests[0].body.installId);
  assert.equal(recordOf(first).token.split(".").length, 3);
  assert.deepEqual(recordOf(first).activatedModels, ["tongue"]);
  assert.equal(kept[`ai.desertant.license.${first.appId}`], undefined);
  if (process.platform !== "win32") assert.equal(statSync(join(first.stateDir, "tongue.json")).mode & 0o777, 0o600);
  assert.equal(existsSync(join(first.stateDir, "tongue.json.lock")), false);

  const second = await runChild(loadDetectFlush, { state: first.stateDir, app: first.appId });
  assertClean(second);
  assert.deepEqual(second.result, first.result);
  assert.equal(second.requests.length, 0);
  assert.deepEqual(stateOf(first.stateDir), kept);

  const other = await runChild(loadDetectFlush, { state: first.stateDir });
  assertClean(other);
  assert.equal(other.requests.length, 1);
  assert.equal(other.requests[0].body.installId, first.requests[0].body.installId);
});

test("a store the app sets as __dalUsageStore is used in place of the state file", async () => {
  const store = join(directory, "injected.json");
  const first = await runChild(loadDetectFlush, { store });
  assertClean(first);
  assert.equal(first.requests.length, 1);
  assert.equal(JSON.parse(readFileSync(store, "utf8"))["ai.desertant.usage.deviceId"], first.requests[0].body.installId);
  assert.equal(existsSync(join(first.stateDir, "tongue.json")), false);
  const second = await runChild(loadDetectFlush, { store, app: first.appId });
  assertClean(second);
  assert.equal(second.requests.length, 0);
});

test("a state folder that cannot be written falls back to memory with one warning, and the model still answers", async () => {
  const blocker = join(directory, "not-a-folder");
  writeFileSync(blocker, "");
  const run = await runChild(loadDetectFlush, { state: join(blocker, "state") });
  assertClean(run);
  assert.deepEqual(run.result, { language: "de", flushed: true, again: true });
  assert.equal(run.requests.length, 1);
  assert.equal(run.stderr.match(/cannot be kept on disk/g)?.length, 1, run.stderr);
  assert.match(run.stderr, /DAL_STATE_DIR/);
  assert.equal(readFileSync(blocker, "utf8"), "");
});

test("a state file that does not parse is replaced with one warning, and the next process is the same install", async () => {
  for (const content of ["", "{ not json", "[]", "null"]) {
    const state = mkdtempSync(join(directory, "state-"));
    writeFileSync(join(state, "tongue.json"), content);
    const first = await runChild(loadDetectFlush, { state });
    assertClean(first);
    assert.equal(first.result.language, "de");
    assert.equal(first.requests.length, 1);
    assert.equal(first.stderr.match(/\[desert-ant\] core: The state file tongue\.json was unreadable and was replaced/g)?.length, 1, first.stderr);
    assert.equal(stateOf(state)["ai.desertant.usage.deviceId"], first.requests[0].body.installId);
    assert.equal(recordOf(first).token.split(".").length, 3);

    const second = await runChild(loadDetectFlush, { state });
    assertClean(second);
    assert.equal(second.stderr, "");
    assert.equal(second.requests[0].body.installId, first.requests[0].body.installId, JSON.stringify(content));
  }
});

const platformNode = JSON.stringify(new URL("../dist/platform.node.js", import.meta.url).href);
const leftovers = (state) => readdirSync(state).filter((name) => name !== "tongue.json");

// Dated an hour ahead, so no run is slow enough to see it as a dead process's lock.
function holdLock(state) {
  const lock = join(state, "tongue.json.lock");
  const ahead = new Date(Date.now() + 3_600_000);
  writeFileSync(lock, "");
  utimesSync(lock, ahead, ahead);
}

test("while another process holds the lock, a stored install id is still used and a new one is never sent", async () => {
  const stored = "7f9c2ba4-e88f-4c6e-9b1a-3d5e8a2f6c01";
  const withId = mkdtempSync(join(directory, "state-"));
  writeFileSync(join(withId, "tongue.json"), JSON.stringify({ "ai.desertant.usage.deviceId": stored }));
  holdLock(withId);
  const first = await runChild(loadDetectFlush, { state: withId });
  assertClean(first);
  assert.deepEqual(first.result, { language: "de", flushed: true, again: true });
  assert.deepEqual(first.requests.map((request) => request.body.installId), [stored]);
  assert.equal(first.stderr, "");
  assert.deepEqual(stateOf(withId), { "ai.desertant.usage.deviceId": stored });

  const empty = mkdtempSync(join(directory, "state-"));
  holdLock(empty);
  const second = await runChild(loadDetectFlush, { state: empty });
  assertClean(second);
  assert.deepEqual(second.result, { language: "de", flushed: true, again: true });
  assert.deepEqual(second.requests, []);
  assert.equal(second.stderr, "");
  assert.deepEqual(leftovers(empty), ["tongue.json.lock"]);

  rmSync(join(empty, "tongue.json.lock"));
  const third = await runChild(loadDetectFlush, { state: empty });
  assertClean(third);
  assert.equal(third.requests.length, 1);
  assert.equal(stateOf(empty)["ai.desertant.usage.deviceId"], third.requests[0].body.installId);
});

test("a process that waits for the lock exits without waiting for it", async () => {
  const state = mkdtempSync(join(directory, "state-"));
  holdLock(state);
  const run = await runChild(`
(await import(${platformNode})).stateLock.waitMs = 45_000;
const { Tongue } = await load();
const tongue = await Tongue.load();
say({ language: tongue.detect(TEXT).language });
`, { state });
  assertClean(run);
  assert.equal(run.result.language, "de");
  assert.deepEqual(run.requests, []);
  assert.ok(run.exitAfterMs < 20_000, `the process ended ${Math.round(run.exitAfterMs)} ms after its last line, so it waited for the lock`);
});

test("a lock left by a process that died is taken over, as a file or as a folder", async () => {
  const old = new Date(Date.now() - 60_000);
  const cases = {
    "an old file": (lock) => { writeFileSync(lock, ""); utimesSync(lock, old, old); },
    "an old folder": (lock) => { mkdirSync(lock); writeFileSync(join(lock, "inner"), ""); utimesSync(lock, old, old); },
  };
  for (const [name, make] of Object.entries(cases)) {
    const state = mkdtempSync(join(directory, "state-"));
    make(join(state, "tongue.json.lock"));
    const run = await runChild(loadDetectFlush, { state });
    assertClean(run);
    assert.equal(run.stderr, "", name);
    assert.equal(run.requests.length, 1, name);
    assert.equal(stateOf(state)["ai.desertant.usage.deviceId"], run.requests[0].body.installId, name);
    assert.equal(recordOf(run).token.split(".").length, 3, name);
    assert.deepEqual(leftovers(state), [], name);
  }
});

test("processes that see the same dead lock at once all keep their records and one install id", async () => {
  const state = mkdtempSync(join(directory, "state-"));
  const old = new Date(Date.now() - 60_000);
  writeFileSync(join(state, "tongue.json.lock"), "");
  utimesSync(join(state, "tongue.json.lock"), old, old);
  const runs = await Promise.all([1, 2, 3, 4].map(() => runChild(loadDetectFlush, { state })));
  for (const run of runs) {
    assertClean(run);
    assert.equal(run.stderr, "");
    assert.equal(run.requests.length, 1);
    assert.equal(recordOf(run).token.split(".").length, 3);
  }
  assert.deepEqual([...new Set(runs.map((run) => run.requests[0].body.installId))], [stateOf(state)["ai.desertant.usage.deviceId"]]);
  assert.deepEqual(leftovers(state), []);
});

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function until(condition, what) {
  const deadline = Date.now() + 30_000;
  while (!condition() && Date.now() < deadline) await sleep(20);
  assert.ok(condition(), what);
}

// The first process stops inside its write until the test lets it go, so the order of the two never depends on timing.
test("a process whose write stalls past the stale time loses the lock, and does not send an install id of its own", async () => {
  const state = mkdtempSync(join(directory, "state-"));
  const marks = mkdtempSync(join(directory, "marks-"));
  const stalling = join(marks, "stalling");
  const release = join(marks, "release");
  const staleMs = 400;
  const shortStale = `(await import(${platformNode})).stateLock.staleMs = ${staleMs};`;
  const stalled = runChild(`
${shortStale}
const fs = await import("node:fs");
const { syncBuiltinESMExports } = await import("node:module");
const handle = await fs.promises.open(process.execPath, "r");
const proto = Object.getPrototypeOf(handle);
await handle.close();
const sync = proto.sync;
let stalls = 0;
proto.sync = async function () {
  if (stalls === 0) {
    stalls += 1;
    fs.writeFileSync(${JSON.stringify(stalling)}, "");
    while (!fs.existsSync(${JSON.stringify(release)})) await new Promise((resolve) => setTimeout(resolve, 20));
  }
  return sync.call(this);
};
const rename = fs.promises.rename;
let renames = 0;
fs.promises.rename = async (from, to) => {
  if (String(to).endsWith("tongue.json")) renames += 1;
  return rename(from, to);
};
syncBuiltinESMExports();
const { Tongue } = await load();
const tongue = await Tongue.load();
const language = tongue.detect(TEXT).language;
const flushed = await tongue.flushLicenses();
say({ language, flushed, stalls, renames });
`, { state });
  await until(() => existsSync(stalling), "the first process never reached its write");
  assert.equal(existsSync(join(state, "tongue.json")), false);
  await sleep(staleMs + 300);
  const other = await runChild(shortStale + loadDetectFlush, { state });
  assertClean(other);
  assert.equal(other.stderr, "");
  assert.equal(other.requests.length, 1);
  const kept = stateOf(state)["ai.desertant.usage.deviceId"];
  assert.equal(other.requests[0].body.installId, kept);

  writeFileSync(release, "");
  const first = await stalled;
  assertClean(first);
  assert.equal(first.stderr, "");
  assert.deepEqual(first.result, { language: "de", flushed: true, stalls: 1, renames: 0 });
  assert.deepEqual(first.requests, [], "the process that lost the lock sent an install id");
  assert.equal(stateOf(state)["ai.desertant.usage.deviceId"], kept);
  assert.deepEqual(leftovers(state), []);

  const restarted = await runChild(loadDetectFlush, { state, app: first.appId });
  assertClean(restarted);
  assert.deepEqual(restarted.requests.map((request) => request.body.installId), [kept]);
});

test("values in the state file that this version does not know are kept", async () => {
  const state = mkdtempSync(join(directory, "state-"));
  const stored = "7f9c2ba4-e88f-4c6e-9b1a-3d5e8a2f6c01";
  const unknown = { later: { nested: [1, 2] }, count: 3, flag: true, nothing: null };
  writeFileSync(join(state, "tongue.json"), JSON.stringify({ ...unknown, "ai.desertant.usage.deviceId": stored }));
  const run = await runChild(loadDetectFlush, { state });
  assertClean(run);
  assert.equal(run.stderr, "");
  assert.deepEqual(run.requests.map((request) => request.body.installId), [stored]);
  const { [`ai.desertant.tongue.license.${run.appId}`]: record, ...rest } = stateOf(state);
  assert.equal(JSON.parse(record).token.split(".").length, 3);
  assert.deepEqual(rest, { ...unknown, "ai.desertant.usage.deviceId": stored });
});

test("a holder of the lock removes temp files a dead process left, and leaves new ones", async () => {
  const state = mkdtempSync(join(directory, "state-"));
  const old = new Date(Date.now() - 60_000);
  for (const name of ["tongue.json.4242.k3x9.tmp", "tongue.json.lock.4242.k3x9.probe"]) {
    writeFileSync(join(state, name), "{}");
    utimesSync(join(state, name), old, old);
  }
  writeFileSync(join(state, "tongue.json.4243.z8q1.tmp"), "{}");
  writeFileSync(join(state, "tongue.json.backup"), "{}");
  utimesSync(join(state, "tongue.json.backup"), old, old);
  const run = await runChild(loadDetectFlush, { state });
  assertClean(run);
  assert.equal(run.requests.length, 1);
  assert.deepEqual(leftovers(state).sort(), ["tongue.json.4243.z8q1.tmp", "tongue.json.backup"]);
});

const onWindows = (failures) => `
Object.defineProperty(process, "platform", { value: "win32" });
const fsPromises = (await import("node:fs")).promises;
const { syncBuiltinESMExports } = await import("node:module");
const open = fsPromises.open;
let refused = 0;
fsPromises.open = async (path, flags, ...rest) => {
  if (String(path).endsWith("tongue.json.lock") && flags === "wx" && refused < ${failures}) {
    refused += 1;
    throw Object.assign(new Error("EPERM: operation not permitted, open"), { code: "EPERM" });
  }
  return open(path, flags, ...rest);
};
syncBuiltinESMExports();
${loadDetectFlush}`;

test("on Windows a lock that cannot be opened yet counts as held, and never as a broken folder", async () => {
  const passing = await runChild(onWindows(3));
  assertClean(passing);
  assert.equal(passing.stderr, "");
  assert.equal(passing.requests.length, 1);
  assert.equal(stateOf(passing.stateDir)["ai.desertant.usage.deviceId"], passing.requests[0].body.installId);

  const never = await runChild(onWindows(Infinity));
  assertClean(never);
  assert.equal(never.stderr, "");
  assert.deepEqual(never.requests, []);
  assert.deepEqual(never.result, { language: "de", flushed: true, again: true });
});

test("two processes that start at once keep both records and one install id", async () => {
  const state = mkdtempSync(join(directory, "state-"));
  const runs = await Promise.all([1, 2, 3].map(() => runChild(loadDetectFlush, { state })));
  for (const run of runs) {
    assertClean(run);
    assert.equal(run.requests.length, 1);
    assert.equal(run.stderr, "");
    assert.equal(recordOf(run).token.split(".").length, 3);
  }
  const installIds = new Set(runs.map((run) => run.requests[0].body.installId));
  assert.deepEqual([...installIds], [stateOf(state)["ai.desertant.usage.deviceId"]]);
  assert.equal(Object.keys(stateOf(state)).length, 4);
});

test("writes from several processes to the state file all land", async () => {
  const state = mkdtempSync(join(directory, "state-"));
  const writer = `
const { stateFile } = await import(${platformNode});
const file = stateFile(() => {});
const keepAlive = setInterval(() => {}, 1000);
for (let index = 0; index < 10; index += 1) await file.put(process.env.DAL_APP_ID + "." + index, "value-" + index, false);
say({ kept: await file.put(process.env.DAL_APP_ID + ".0", "other", true) });
clearInterval(keepAlive);
`;
  const runs = await Promise.all(["w1", "w2", "w3", "w4"].map((app) => runChild(writer, { state, app })));
  for (const run of runs) {
    assertClean(run);
    assert.deepEqual(run.result, { kept: "value-0" });
  }
  const kept = stateOf(state);
  assert.equal(Object.keys(kept).length, 40);
  for (const app of ["w1", "w2", "w3", "w4"]) assert.equal(kept[`${app}.9`], "value-9");
  assert.equal(existsSync(join(state, "tongue.json.lock")), false);
});

test("a refusal is kept for a day, and the model keeps answering", async () => {
  const first = await runChild(loadDetectFlush, { mode: "refuse" });
  assertClean(first);
  assert.deepEqual(first.result, { language: "de", flushed: true, again: true });
  assert.equal(first.requests.length, 1);
  assert.equal(recordOf(first).token, undefined);
  assert.ok(Math.abs(recordOf(first).refusedAt.tongue - Date.now()) < 60_000);

  const second = await runChild(loadDetectFlush, { mode: "refuse", state: first.stateDir, app: first.appId });
  assertClean(second);
  assert.equal(second.requests.length, 0);
});

test("a token that does not verify is not stored", async () => {
  const run = await runChild(loadDetectFlush, { mode: "tampered-token" });
  assertClean(run);
  assert.equal(run.result.language, "de");
  assert.equal(run.requests.length, 1);
  assert.equal(recordOf(run).token, undefined);
  assert.equal(typeof recordOf(run).refusedAt.tongue, "number");
});

const outage = `
const { Tongue } = await load();
const started = performance.now();
const tongue = await Tongue.load();
const first = tongue.detect(TEXT);
const elapsed = performance.now() - started;
await new Promise((resolve) => setTimeout(resolve, 300));
const second = tongue.detect(TEXT, 2);
say({ first, second, elapsed });
process.exit(process.exitCode ?? 0);
`;

test("with the license server down, slow or wrong, the model answers at once and the same", async () => {
  const baseline = await runChild(outage);
  assertClean(baseline);
  assert.equal(baseline.result.first.language, "de");
  for (const mode of ["dead-port", "silent", "unavailable", "captive-portal", "refuse", "tampered-token"]) {
    const run = await runChild(outage, mode === "dead-port" ? { endpoint: DEAD_ENDPOINT } : { mode });
    assertClean(run);
    assert.deepEqual(run.result.first, baseline.result.first, mode);
    assert.deepEqual(run.result.second.candidates, baseline.result.second.candidates, mode);
    assert.ok(run.result.elapsed < 8000, `${mode}: the first detection took ${Math.round(run.result.elapsed)} ms`);
    if (mode !== "dead-port") assert.equal(run.requests.length, 1, mode);
  }
});

test("a runtime with no AbortSignal.timeout still ends a request after 10 seconds", async () => {
  const script = `
delete AbortSignal.timeout;
const timers = [];
let cleared = 0;
const realSet = globalThis.setTimeout;
const realClear = globalThis.clearTimeout;
globalThis.setTimeout = (work, delay, ...rest) => {
  const timer = realSet(work, delay === 10000 ? 200 : delay, ...rest);
  if (delay === 10000) timers.push(timer);
  return timer;
};
globalThis.clearTimeout = (timer) => { if (timers.includes(timer)) cleared += 1; return realClear(timer); };
const { Tongue } = await load();
const tongue = await Tongue.load();
const started = performance.now();
const flushed = await tongue.flushLicenses();
say({ flushed, waited: performance.now() - started, timers: timers.length, cleared });
process.exit(process.exitCode ?? 0);
`;
  const silent = await runChild(script, { mode: "silent" });
  assertClean(silent);
  assert.equal(silent.requests.length, 1);
  assert.deepEqual({ ...silent.result, waited: 0 }, { flushed: true, waited: 0, timers: 1, cleared: 1 });
  assert.ok(silent.result.waited >= 150 && silent.result.waited < 8000, `the request ended after ${silent.result.waited} ms`);

  const granted = await runChild(script);
  assertClean(granted);
  assert.deepEqual({ ...granted.result, waited: 0 }, { flushed: true, waited: 0, timers: 1, cleared: 1 });
  assert.equal(recordOf(granted).token.split(".").length, 3);
});

const devices = (ids, extra = "") => `
const { Tongue, DesertAnt } = await load();
DesertAnt.configure({ apiKey: "dal_server_key", deviceIdSecret: ${JSON.stringify(SECRET)} });
const tongue = await Tongue.load();
const ids = ${ids};
const round = () => ids.map((deviceId, index) =>
  tongue.detect(TEXT, index === 0 ? { topK: 1, deviceId: () => deviceId } : { deviceId }));
const detections = [...round(), ...round()];
const started = performance.now();
const flushed = await tongue.flushLicenses();
const waited = performance.now() - started;
round();
${extra}
say({
  flushed,
  waited,
  again: await tongue.flushLicenses(),
  languages: [...new Set(detections.map((one) => one.language))],
  candidates: detections.slice(0, 3).map((one) => one.candidates.length),
});
process.exit(process.exitCode ?? 0);
`;

const expectedInstallIds = (ids, run) => Promise.all(ids.map((id) => deviceInstallId(id, `server:${run.appId}`, SECRET)));

test("a server with a secret asks for its devices in one batch at the flush, and not for itself", async () => {
  const run = await runChild(devices(JSON.stringify(DEVICE_IDS)));
  assertClean(run);
  assert.deepEqual({ ...run.result, waited: 0 }, { flushed: true, waited: 0, again: true, languages: ["de"], candidates: [1, 3, 3] });
  assert.ok(run.result.waited < 8000, `the flush waited ${run.result.waited} ms for a partial batch`);
  assert.equal(run.requests.length, 1);
  const [request] = run.requests;
  assert.equal(request.path, "/api/v1/licenses");
  assert.equal(request.headers.authorization, undefined);
  assert.deepEqual(request.body, {
    sdk: { name: "desert-ant-core", version: sdkVersion },
    platform: "server",
    app: { id: run.appId },
    key: "dal_server_key",
    items: (await expectedInstallIds(DEVICE_IDS, run)).map((installId) => ({ installId, model: "tongue", modelVersion })),
  });
  assert.equal(JSON.stringify(request.body).includes("device-"), false);
  assert.equal(existsSync(join(run.stateDir, "tongue.json")), false);
});

test("250 devices in a burst make 3 batch requests of 100, 100 and 50, and no single request", async () => {
  const ids = Array.from({ length: 250 }, (_, index) => `device-${index}`);
  const run = await runChild(devices(JSON.stringify(ids)));
  assertClean(run);
  assert.equal(run.result.flushed, true);
  assert.deepEqual(run.requests.map((request) => request.path), Array(3).fill("/api/v1/licenses"));
  assert.deepEqual(run.requests.map((request) => request.body.items.length), [100, 100, 50]);
  assert.deepEqual(
    run.requests.flatMap((request) => request.body.items.map((item) => item.installId)),
    await expectedInstallIds(ids, run),
  );
});

test("when the server has no batch route, each device is one request", async () => {
  const run = await runChild(devices(JSON.stringify(DEVICE_IDS)), { mode: "no-batch" });
  assertClean(run);
  assert.equal(run.result.flushed, true);
  assert.deepEqual(run.requests.map((request) => request.path), ["/api/v1/licenses", ...Array(3).fill("/api/v1/license")]);
  assert.deepEqual(run.requests.slice(1).map((request) => request.body.installId), await expectedInstallIds(DEVICE_IDS, run));
  assert.equal(run.stderr, "");
});

test("a batch of tokens that do not verify is not asked for again", async () => {
  const run = await runChild(devices(JSON.stringify(DEVICE_IDS)), { mode: "tampered-token" });
  assertClean(run);
  assert.equal(run.result.flushed, true);
  assert.equal(run.requests.length, 1);
});

test("flushLicenses resolves false while device licenses still wait", async () => {
  for (const options of [{ mode: "unavailable" }, { endpoint: DEAD_ENDPOINT }]) {
    const run = await runChild(devices(JSON.stringify(DEVICE_IDS)), options);
    assertClean(run);
    assert.equal(run.result.flushed, false);
    assert.equal(run.result.again, false);
    assert.deepEqual(run.result.languages, ["de"]);
    assert.equal(run.stderr.match(/Device licensing failed/g)?.length, 1, run.stderr);
  }
});

test("a server with no secret licenses itself and each device id, and a call with no device id asks nothing more", async () => {
  const run = await runChild(`
const { Tongue } = await load();
const tongue = await Tongue.load();
tongue.detect(TEXT);
tongue.detect(TEXT, { deviceId: "device-7" });
tongue.detect(TEXT, { deviceId: 7 });
say({ flushed: await tongue.flushLicenses() });
`);
  assertClean(run);
  assert.equal(run.result.flushed, true);
  assert.deepEqual(run.requests.map((request) => request.path), ["/api/v1/license", "/api/v1/license"]);
  const device = await deviceInstallId("device-7", `server:${run.appId}`, null);
  assert.equal(run.requests.filter((request) => request.body.installId === device).length, 1);
  assert.match(run.stderr, /hashed without a secret/);
});

test("the log level and the logger that any Desert Ant package sets reach Tongue", async () => {
  const script = (setup) => `
const { Tongue, DesertAnt } = await load();
const messages = [];
${setup}
DesertAnt.configure({ apiKey: "dal_server_key", deviceIdSecret: ${JSON.stringify(SECRET)} });
const tongue = await Tongue.load();
tongue.detect(TEXT);
tongue.detect(TEXT, { deviceId: "device-1" });
await tongue.flushLicenses();
const errors = [];
for (const set of [() => (DesertAnt.logLevel = "loud"), () => (DesertAnt.logger = "console")]) {
  try { set(); } catch (error) { errors.push(error.message); }
}
say({ messages, level: DesertAnt.logLevel, hasLogger: DesertAnt.logger !== null, errors });
process.exit(process.exitCode ?? 0);
`;
  const byDefault = await runChild(script(""), { mode: "unavailable" });
  assertClean(byDefault);
  assert.equal(byDefault.result.level, "warning");
  assert.equal(byDefault.result.hasLogger, false);
  assert.match(byDefault.stderr, /\[desert-ant\] core: This call has no deviceId/);
  assert.match(byDefault.stderr, /\[desert-ant\] core: Device licensing failed \(HTTP 503\)/);
  assert.deepEqual(byDefault.result.errors, [
    "DesertAnt.logLevel: expected one of debug, info, warning, error, off, got loud",
    "DesertAnt.logger: expected a function or null",
  ]);

  const off = await runChild(script('globalThis.__dalLogLevel = "silent";'), { mode: "unavailable" });
  assertClean(off);
  assert.equal(off.result.level, "off");
  assert.equal(off.stderr, "");

  const shared = await runChild(script('globalThis.__dalLog = (level, source, message) => messages.push([level, source, message.split(",")[0]]);'), { mode: "unavailable" });
  assertClean(shared);
  assert.equal(shared.stderr, "");
  assert.equal(shared.result.hasLogger, true);
  assert.deepEqual(shared.result.messages.map(([level, source]) => [level, source]), [["warning", "core"], ["warning", "core"]]);

  const own = await runChild(script('DesertAnt.logLevel = "error"; DesertAnt.logger = (...parts) => messages.push(parts);'), { mode: "unavailable" });
  assertClean(own);
  assert.deepEqual(own.result, { messages: [], level: "error", hasLogger: true, errors: byDefault.result.errors });
  assert.equal(own.stderr, "");

  const info = await runChild(script('DesertAnt.logLevel = "info"; DesertAnt.logger = (level) => messages.push(level);'), { mode: "no-batch" });
  assertClean(info);
  assert.deepEqual(info.result.messages, ["warning", "info"]);
});

test("a key set through the shared configure state reaches Tongue, and Tongue's configure reaches the other cores", async () => {
  const run = await runChild(`
const applied = [];
let coreFlushes = 0;
const state = globalThis[Symbol.for("desert-ant-labs.configure")];
state.cores.add((settings) => applied.push(settings));
state.settings = { apiKey: "dal_shared_key", deviceIdSecret: null };
const { Tongue, DesertAnt } = await load();
const tongue = await Tongue.load();
const flushed = await tongue.flushLicenses();
state.flushes.add(async () => { coreFlushes += 1; return false; });
const withCore = await tongue.flushLicenses();
DesertAnt.configure({ apiKey: "dal_other_key" });
const errors = [];
for (const settings of [undefined, { apiKey: 7 }, { apiKey: "dal_x", deviceIdSecret: " " }]) {
  try { DesertAnt.configure(settings); } catch (error) { errors.push(error.constructor.name + ": " + error.message); }
}
globalThis.window = { document: {} };
try { DesertAnt.configure({ apiKey: "dal_x", deviceIdSecret: "s".repeat(32) }); } catch (error) { errors.push(error.message); }
say({ flushed, withCore, coreFlushes, applied, settings: state.settings, registered: state.flushes.size, errors });
`, { coreFirst: true });
  assertClean(run);
  assert.equal(run.requests.length, 1);
  assert.equal(run.requests[0].body.key, "dal_shared_key");
  assert.deepEqual(run.result, {
    flushed: true,
    withCore: false,
    coreFlushes: 1,
    applied: [{ apiKey: "dal_other_key", deviceIdSecret: null }],
    settings: { apiKey: "dal_other_key", deviceIdSecret: null },
    registered: 2,
    errors: [
      "TypeError: DesertAnt.configure: apiKey must be a string",
      "TypeError: DesertAnt.configure: apiKey must be a string",
      "TypeError: DesertAnt.configure: deviceIdSecret must be a non-empty string",
      "DesertAnt.configure: deviceIdSecret is for servers. A secret in a page or a worker is public.",
    ],
  });
});

test("in a page the app is the hostname, the platform is web and the record is in localStorage", async () => {
  const run = await runChild(`
Object.defineProperty(process, "versions", { value: { ...process.versions, node: undefined } });
const kept = new Map();
globalThis.localStorage = { getItem: (key) => kept.get(key) ?? null, setItem: (key, value) => void kept.set(key, value) };
globalThis.location = { hostname: "app.example.test" };
globalThis.__dalLicenseEndpoint = () => "http://license.example.test/api/v1/";
const calls = [];
globalThis.fetch = async (url, init) => {
  calls.push({ url, headers: init.headers, body: JSON.parse(init.body) });
  return { status: 422, headers: { get: () => null }, text: async () => '{"error":"invalid_license"}' };
};
const { Tongue, DesertAnt } = await load();
DesertAnt.configure({ apiKey: "dal_page_key" });
const tongue = await Tongue.load();
const language = tongue.detect(TEXT, { deviceId: "device-1" }).language;
const flushed = await tongue.flushLicenses();
await Tongue.load();
await tongue.flushLicenses();
say({ language, flushed, calls, keys: [...kept.keys()].sort(), record: JSON.parse(kept.get("ai.desertant.tongue.license.dal_page_key")) });
`);
  assertClean(run);
  const { calls, record, ...rest } = run.result;
  assert.deepEqual(rest, {
    language: "de",
    flushed: true,
    keys: ["ai.desertant.tongue.license.dal_page_key", "ai.desertant.usage.deviceId"],
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "http://license.example.test/api/v1/license");
  assert.deepEqual(calls[0].headers, { "Content-Type": "application/json" });
  assert.equal(calls[0].body.platform, "web");
  assert.deepEqual(calls[0].body.app, { id: "app.example.test" });
  assert.equal(calls[0].body.key, "dal_page_key");
  assert.deepEqual(Object.keys(record.refusedAt), ["tongue"]);
  assert.equal(run.requests.length, 0);
  assert.equal(existsSync(join(run.stateDir, "tongue.json")), false);
});
