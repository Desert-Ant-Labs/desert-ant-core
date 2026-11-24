#!/usr/bin/env node
// The license client in a real browser: `npm run test:browser`, with `-- --headed` to watch and `DAL_BROWSER_ENGINE` for another engine.
import assert from "node:assert/strict";
import { createPrivateKey, randomUUID, sign } from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

process.env.DAL_LICENSE_ENDPOINT = "http://127.0.0.1:9/api/v1";
// The Node side loads the model too, and must not write the developer's own state file.
process.env.DAL_STATE_DIR = fs.mkdtempSync(path.join(os.tmpdir(), "tongue-browser-"));
process.on("exit", () => fs.rmSync(process.env.DAL_STATE_DIR, { recursive: true, force: true }));

const PACKAGE = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const REPO = path.resolve(PACKAGE, "../..");
const ENGINE = process.env.DAL_BROWSER_ENGINE ?? "chromium";
const TEXT = "kann ich das haben";
const API_KEY = "dal_browser_key";
const INSECURE_HOST = "tongue.test";

const vectors = JSON.parse(fs.readFileSync(path.join(REPO, "Tests/UsageTests/Resources/license_vectors.json"), "utf8"));
const testKey = vectors.keys.find((key) => key.kid === "test-2");
const sdkVersion = fs.readFileSync(path.join(REPO, "VERSION"), "utf8").trim();
const modelVersion = /revision = "([^"]+)"/.exec(fs.readFileSync(path.join(REPO, "Sources/Tongue/Catalog.swift"), "utf8"))[1];

if (!fs.existsSync(path.join(PACKAGE, "dist", "license.js"))) {
  console.error("error: no dist/; run `npm run build` first");
  process.exit(1);
}

const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");

function signedToken() {
  const now = Date.now();
  const input = [
    encode({ alg: "ES256", kid: testKey.kid, typ: "dal-license+jwt" }),
    encode({
      v: 1,
      lid: randomUUID(),
      period: new Date(now).toISOString().slice(0, 7),
      periodEnd: new Date(now + 30 * 24 * 60 * 60 * 1000).toISOString(),
      iat: Math.floor(now / 1000) - 5,
    }),
  ].join(".");
  const key = createPrivateKey({ key: Buffer.from(testKey.privateKeyPkcs8, "base64"), format: "der", type: "pkcs8" });
  return `${input}.${sign("sha256", Buffer.from(input), { key, dsaEncoding: "ieee-p1363" }).toString("base64url")}`;
}

// A license that is in its period, so only the signature check can turn it down.
function tamperedToken() {
  const [header, payload, signature] = signedToken().split(".");
  const changed = { ...JSON.parse(Buffer.from(payload, "base64url").toString()), lid: randomUUID() };
  return `${header}.${encode(changed)}.${signature}`;
}

const listen = (server) => new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(0, "127.0.0.1", () => resolve(server.address().port));
});

const PAGE = `<!doctype html>
<html><body>
<script type="importmap">${JSON.stringify({ imports: { "/dist/platform.js": "/dist/platform.browser.js" } })}</script>
</body></html>`;
const MIME = { ".js": "text/javascript", ".json": "application/json", ".bin": "application/octet-stream" };

const served = [];
const site = http.createServer((req, res) => {
  const { pathname } = new URL(req.url, "http://localhost");
  served.push(pathname);
  if (pathname === "/") {
    res.writeHead(200, { "content-type": "text/html" });
    return res.end(PAGE);
  }
  const file = path.join(PACKAGE, pathname);
  if (!file.startsWith(path.join(PACKAGE, "dist") + path.sep) || !fs.existsSync(file)) {
    res.writeHead(404);
    return res.end("not found");
  }
  res.writeHead(200, { "content-type": MIME[path.extname(file)] ?? "application/octet-stream" });
  res.end(fs.readFileSync(file));
});

const grants = {
  grant: () => ({ token: signedToken(), serverTime: new Date().toISOString() }),
  "tampered-token": () => ({ token: tamperedToken(), serverTime: new Date().toISOString() }),
  silent: null,
};

// The CORS answers of dal-core (backend/src/common/cors.ts) for the license paths.
const seen = {};
const licenses = http.createServer((req, res) => {
  const [, run, mode] = req.url.split("/");
  let body = "";
  req.on("data", (chunk) => (body += chunk));
  req.on("end", () => {
    (seen[run] ??= []).push({ method: req.method, path: req.url, headers: req.headers, body });
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Expose-Headers", "Retry-After");
    res.setHeader("Vary", "Origin");
    if (req.method === "OPTIONS") {
      res.setHeader("Access-Control-Allow-Methods", "GET, POST, PATCH, DELETE, OPTIONS");
      res.setHeader("Access-Control-Allow-Headers", "authorization, content-type, x-team");
      res.setHeader("Access-Control-Max-Age", "86400");
      res.writeHead(204);
      return res.end();
    }
    if (!grants[mode]) return;
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify(grants[mode]()));
  });
});

const sitePort = await listen(site);
const licensePort = await listen(licenses);
const closed = http.createServer();
const closedPort = await listen(closed);
await new Promise((resolve) => closed.close(resolve));

async function inPage({ kid, key, apiKey, text, flush }) {
  const rejections = [];
  addEventListener("unhandledrejection", (event) => rejections.push(String(event.reason)));
  const license = await import("/dist/license.js");
  license.licensePublicKeys[kid] = key;
  const { Tongue, DesertAnt } = await import("/dist/index.js");
  let secretError = null;
  try {
    DesertAnt.configure({ apiKey, deviceIdSecret: "s".repeat(32) });
  } catch (error) {
    secretError = `${error.name}: ${error.message}`;
  }
  DesertAnt.configure({ apiKey });
  const tongue = await Tongue.load({ from: "/dist" });
  const started = performance.now();
  const detection = tongue.detect(text, { deviceId: "device-1" });
  const detectMs = performance.now() - started;
  const flushed = flush ? await tongue.flushLicenses() : null;
  await new Promise((resolve) => setTimeout(resolve, 100));
  return {
    secretError,
    detection,
    detectMs,
    flushed,
    storage: Object.fromEntries(Object.keys(localStorage).map((name) => [name, localStorage.getItem(name)])),
    verifies: globalThis.__verifies,
    subtle: typeof globalThis.crypto?.subtle,
    secure: globalThis.isSecureContext,
    hostname: location.hostname,
    userAgent: navigator.userAgent,
    rejections,
  };
}

function spyOnVerify() {
  globalThis.__verifies = [];
  const subtle = globalThis.crypto?.subtle;
  if (!subtle) return;
  const verify = subtle.verify.bind(subtle);
  subtle.verify = async (...args) => {
    const valid = await verify(...args);
    globalThis.__verifies.push(valid);
    return valid;
  };
}

const { Tongue } = await import(path.join(PACKAGE, "dist", "index.js"));
const expected = (await Tongue.load()).detect(TEXT);

function assertSameDetection(actual, label) {
  assert.equal(actual.language, expected.language, label);
  assert.equal(actual.reliability, expected.reliability, label);
  assert.equal(actual.normalized, expected.normalized, label);
  assert.deepEqual(actual.candidates.map((one) => one.language), expected.candidates.map((one) => one.language), label);
  actual.candidates.forEach((one, index) =>
    assert.ok(Math.abs(one.probability - expected.candidates[index].probability) < 1e-9, `${label}: probability ${index}`));
}

const playwright = await import("playwright");
const engine = playwright[ENGINE];
if (!engine) {
  console.error(`error: unknown DAL_BROWSER_ENGINE "${ENGINE}" (chromium, webkit, firefox)`);
  process.exit(1);
}
// The mapped host is a plain http origin that is not localhost, which is where a browser has no crypto.subtle.
const browser = await engine.launch({
  headless: !process.argv.includes("--headed"),
  args: ENGINE === "chromium" ? [`--host-resolver-rules=MAP ${INSECURE_HOST} 127.0.0.1`] : [],
});

async function open(mode, { host = "localhost", endpoint } = {}) {
  const run = randomUUID();
  const context = await browser.newContext();
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript(spyOnVerify);
  await page.addInitScript((url) => {
    globalThis.__dalLicenseEndpoint = url;
  }, endpoint ?? `http://127.0.0.1:${licensePort}/${run}/${mode}/api/v1`);
  const origin = `http://${host}:${sitePort}`;
  const visit = async (flush = true) => {
    served.length = 0;
    await page.goto(`${origin}/`);
    const result = await page.evaluate(inPage, { kid: testKey.kid, key: testKey.publicKeyX963, apiKey: API_KEY, text: TEXT, flush });
    assert.deepEqual(errors, [], "the page threw");
    assert.deepEqual(result.rejections, [], "unhandled rejections in the page");
    assert.ok(served.includes("/dist/platform.browser.js"), "the page did not load the browser platform file");
    assert.ok(!served.includes("/dist/platform.node.js"), "the page loaded the Node platform file");
    assertSameDetection(result.detection, mode);
    assert.ok(result.detectMs < 1000, `${mode}: the detection took ${result.detectMs} ms`);
    return result;
  };
  const requests = () => seen[run] ?? [];
  const posts = () => requests().filter((request) => request.method === "POST");
  return { visit, requests, posts, origin, close: () => context.close() };
}

async function until(condition, what) {
  const deadline = Date.now() + 5000;
  while (!condition() && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
  assert.ok(condition(), what);
}

const record = (storage) => JSON.parse(storage[`ai.desertant.tongue.license.${API_KEY}`]);
const cases = [];
const add = (name, body, engines = null) => cases.push({ name, body, engines });
const notes = [];

add("a load asks once across origins, verifies with WebCrypto and keeps the license in localStorage", async () => {
  const tab = await open("grant");
  try {
    const first = await tab.visit();
    assert.equal(first.secure, true);
    assert.equal(first.subtle, "object");
    assert.equal(first.secretError, "TypeError: DesertAnt.configure: deviceIdSecret is for servers. A secret in a page or a worker is public.");
    assert.equal(first.flushed, true);
    assert.equal(tab.posts().length, 1);
    const [post] = tab.posts();
    assert.equal(post.path.split("/").slice(3).join("/"), "api/v1/license");
    assert.equal(post.headers.origin, tab.origin);
    assert.notEqual(post.headers.origin, `http://127.0.0.1:${licensePort}`);
    assert.equal(post.headers.authorization, undefined);
    assert.equal(post.headers["content-type"], "application/json");
    const body = JSON.parse(post.body);
    assert.deepEqual(body, {
      installId: body.installId,
      model: "tongue",
      modelVersion,
      sdk: { name: "desert-ant-core", version: sdkVersion },
      platform: "web",
      app: { id: "localhost" },
      key: API_KEY,
    });
    assert.equal(first.storage["ai.desertant.usage.deviceId"], body.installId);
    assert.equal(record(first.storage).token.split(".").length, 3);
    assert.deepEqual(record(first.storage).activatedModels, ["tongue"]);
    assert.ok(first.verifies.length > 0 && first.verifies.every((valid) => valid === true), JSON.stringify(first.verifies));

    const preflights = tab.requests().filter((request) => request.method === "OPTIONS");
    notes.push(`${preflights.length} CORS preflight (OPTIONS) before the POST, asking for "${preflights[0]?.headers["access-control-request-headers"] ?? ""}"`);
    notes.push(first.userAgent);

    const second = await tab.visit();
    assert.equal(tab.posts().length, 1, "the reload asked again");
    assert.equal(second.storage["ai.desertant.usage.deviceId"], body.installId);
    assert.deepEqual(record(second.storage), record(first.storage));
    assert.ok(second.verifies.length > 0 && second.verifies.every((valid) => valid === true), JSON.stringify(second.verifies));
  } finally {
    await tab.close();
  }
});

add("a token with a bad signature is not stored", async () => {
  const tab = await open("tampered-token");
  try {
    const result = await tab.visit();
    assert.equal(tab.posts().length, 1);
    assert.deepEqual(result.verifies, [false]);
    assert.equal(record(result.storage).token, undefined);
    assert.deepEqual(Object.keys(record(result.storage).refusedAt), ["tongue"]);
    await tab.visit();
    assert.equal(tab.posts().length, 1, "the reload asked again within the day");
  } finally {
    await tab.close();
  }
});

add("with the license server unreachable, a detection still answers at once", async () => {
  const tab = await open("grant", { endpoint: `http://127.0.0.1:${closedPort}/api/v1` });
  try {
    const result = await tab.visit();
    assert.equal(result.flushed, true);
    assert.deepEqual(Object.keys(result.storage), ["ai.desertant.usage.deviceId"]);
  } finally {
    await tab.close();
  }
});

add("with a license server that never answers, a detection still answers at once", async () => {
  const tab = await open("silent");
  try {
    await tab.visit(false);
    await until(() => tab.posts().length > 0, "the page sent no license request");
    assert.equal(tab.posts().length, 1);
  } finally {
    await tab.close();
  }
});

add("on a plain http origin with no crypto.subtle the license is kept unverified", async () => {
  const tab = await open("grant", { host: INSECURE_HOST });
  try {
    const result = await tab.visit();
    assert.equal(result.secure, false);
    assert.equal(result.subtle, "undefined");
    assert.equal(tab.posts().length, 1);
    assert.deepEqual(JSON.parse(tab.posts()[0].body).app, { id: INSECURE_HOST });
    assert.equal(record(result.storage).token.split(".").length, 3);
    assert.deepEqual(result.verifies, []);
  } finally {
    await tab.close();
  }
}, ["chromium"]);

let failed = 0;
for (const { name, body, engines } of cases) {
  if (engines && !engines.includes(ENGINE)) {
    console.log(`skip ${name} (${engines.join(", ")} only)`);
    continue;
  }
  const started = Date.now();
  try {
    await body();
    console.log(`ok   ${name}  (${Date.now() - started} ms)`);
  } catch (error) {
    failed += 1;
    console.log(`FAIL ${name}\n${error.stack ?? error}`);
  }
}

const version = browser.version();
await browser.close();
site.close();
licenses.closeAllConnections();
licenses.close();

for (const note of notes) console.log(`note ${note}`);
if (failed) {
  console.error(`\n${failed} of ${cases.length} browser cases failed in ${ENGINE} ${version}`);
  process.exit(1);
}
console.log(`\nall browser cases passed in ${ENGINE} ${version}`);
