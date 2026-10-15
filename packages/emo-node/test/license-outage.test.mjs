import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { after, before, test } from "node:test";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_DIR = path.join(HERE, "fixtures", "model");
const VECTORS = path.join(HERE, "..", "..", "..", "Tests", "UsageTests", "Resources", "license_vectors.json");
const TEXT = "Pay my bills";
const REPLY_DELAY_MS = 4000;
const LOAD_BOUND_MS = 2500;
const CLOSED_PORT = "http://127.0.0.1:9/api/v1";

const tampered = JSON.parse(fs.readFileSync(VECTORS, "utf8")).tokens.find((t) => t.name === "tampered-payload").token;

const json = (status, body, headers = {}) => (res) => {
  res.writeHead(status, { "content-type": "application/json", ...headers });
  res.end(JSON.stringify(body));
};

const modes = {
  silent: null,
  "rate-limited": json(429, { error: "slow_down" }, { "retry-after": "60" }),
  "bad-request": json(400, { error: "invalid_request" }),
  "captive-portal": (res) => {
    res.writeHead(200, { "content-type": "text/html" });
    res.end("<html>captive portal</html>");
  },
  "tampered-token": (res, route) => route === "license"
    ? json(200, { token: tampered, serverTime: new Date().toISOString() })(res)
    : json(503, { error: "retry" })(res),
  "reset-mid-response": (res) => {
    res.writeHead(200, { "content-type": "application/json", "content-length": "200" });
    res.write('{"token":"');
    setTimeout(() => res.socket.destroy(), 20);
  },
};

const seen = Object.fromEntries(Object.keys(modes).map((mode) => [mode, []]));
const answered = Object.fromEntries(Object.keys(modes).map((mode) => [mode, 0]));
const grantAt = {};
const server = http.createServer((req, res) => {
  const [, , mode, , , route] = req.url.split("/");
  res.on("error", () => {});
  req.socket.on("error", () => {});
  req.resume();
  req.on("end", () => {
    if (!(mode in modes)) return json(404, { error: "not_found" })(res);
    seen[mode].push(route);
    if (route === "license") grantAt[mode] ??= performance.now();
    const reply = modes[mode];
    if (!reply) return;
    setTimeout(() => {
      if (res.destroyed) return;
      answered[mode] += 1;
      reply(res, route);
    }, REPLY_DELAY_MS);
  });
});

const child = `
process.on("unhandledRejection", (e) => { console.error("UNHANDLED_REJECTION " + e); process.exitCode = 3; });
const { Emo } = await import(${JSON.stringify(pathToFileURL(path.join(HERE, "..", "node.js")).href)});
const emo = await Emo.load({ directory: ${JSON.stringify(FIXTURE_DIR)} });
const first = await emo.suggestions(${JSON.stringify(TEXT)}, { limit: 5 });
console.log("READY");
await new Promise((resolve) => process.stdin.once("data", resolve));
process.stdin.destroy();
const second = await emo.suggestions(${JSON.stringify(TEXT)}, { limit: 5 });
emo.dispose();
console.log("RESULT " + JSON.stringify({ first, second }));
`;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function until(condition, ms = 15_000) {
  const deadline = performance.now() + ms;
  while (!condition() && performance.now() < deadline) await sleep(50);
}

// The parent says when the child may suggest again and exit, so a slow machine cannot end it before the server has answered.
function runChild(name, endpoint, release) {
  return new Promise((resolve) => {
    const proc = spawn(process.execPath, ["--input-type=module", "-e", child], {
      env: {
        ...process.env,
        DAL_API_KEY: "",
        DAL_LICENSE_ENDPOINT: endpoint,
        DAL_APP_ID: `ai.desertant.emo.outage.${name}.${randomUUID()}`,
      },
    });
    let stdout = "";
    let stderr = "";
    let readyAt;
    let resultAt;
    proc.stdin.on("error", () => {});
    proc.stdout.on("data", (chunk) => {
      stdout += chunk;
      if (!readyAt && stdout.includes("READY")) {
        readyAt = performance.now();
        release().then(() => proc.stdin.end("go\n"));
      }
      if (!resultAt && stdout.includes("RESULT ")) resultAt = performance.now();
    });
    proc.stderr.on("data", (chunk) => (stderr += chunk));
    const timer = setTimeout(() => proc.kill("SIGKILL"), 60_000);
    proc.on("close", (code, signal) => {
      clearTimeout(timer);
      const line = stdout.split("\n").find((l) => l.startsWith("RESULT "));
      resolve({
        code,
        signal,
        stderr,
        readyAt,
        result: line ? JSON.parse(line.slice("RESULT ".length)) : null,
        exitAfterMs: resultAt ? performance.now() - resultAt : null,
      });
    });
  });
}

function assertSameSuggestions(actual, expected, label) {
  assert.deepEqual(actual.map((s) => s.emoji), expected.map((s) => s.emoji), label);
  actual.forEach((s, i) => assert.ok(Math.abs(s.confidence - expected[i].confidence) < 1e-6, `${label}: confidence ${i}`));
}

const FAILURES = [...Object.keys(modes), "dns-failure"];
const runs = {};
before(async () => {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const endpoint = (mode) => mode === "dns-failure"
    ? "http://license.invalid/api/v1"
    : `http://127.0.0.1:${server.address().port}/m/${mode}/api/v1`;
  const release = (mode) => () => mode === "dns-failure"
    ? sleep(2000)
    : until(() => (modes[mode] ? answered[mode] > 0 : seen[mode].includes("license")));
  runs.baseline = await runChild("baseline", CLOSED_PORT, async () => {});
  const results = await Promise.all(FAILURES.map((mode) => runChild(mode, endpoint(mode), release(mode))));
  FAILURES.forEach((mode, i) => (runs[mode] = results[i]));
});
after(() => {
  server.closeAllConnections();
  server.close();
});

const skipReason = () => (runs.baseline?.result || process.env.CI ? null : "the native model did not load here");

test("with no license server, the model loads, suggests and exits cleanly", (t) => {
  if (skipReason()) return t.skip(skipReason());
  const run = runs.baseline;
  assert.equal(run.code, 0, run.stderr);
  assert.ok(run.result, `no result:\n${run.stderr}`);
  assert.ok(run.result.first.some((s) => ["💰", "💳", "🧾", "🏦", "📄"].includes(s.emoji)),
    `got ${run.result.first.map((s) => s.emoji).join(" ")}`);
});

for (const mode of FAILURES) {
  test(`a license server that fails as ${mode} changes nothing for the model`, (t) => {
    if (skipReason()) return t.skip(skipReason());
    const run = runs[mode];
    assert.equal(run.signal, null, run.stderr);
    assert.equal(run.code, 0, run.stderr);
    assert.ok(!run.stderr.includes("UNHANDLED_REJECTION"), run.stderr);
    assert.ok(run.result, `no result:\n${run.stderr}`);
    assertSameSuggestions(run.result.first, runs.baseline.result.first, "first suggestion");
    assertSameSuggestions(run.result.second, runs.baseline.result.first, "suggestion after the server's reply");
    assert.ok(run.exitAfterMs < 2000, `the process took ${Math.round(run.exitAfterMs)} ms to exit`);
    if (mode !== "dns-failure") {
      assert.ok(seen[mode].includes("license"), `the ${mode} server saw no grant`);
      const lag = run.readyAt - grantAt[mode];
      assert.ok(lag < LOAD_BOUND_MS, `the first suggestion came ${Math.round(lag)} ms after the grant reached the server`);
      if (modes[mode]) assert.ok(answered[mode] > 0, `the ${mode} server never answered`);
    }
  });
}
