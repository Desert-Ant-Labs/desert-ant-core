// A process that ends with a usage send pending exits cleanly, within the bound, after the send reaches the server.
import assert from "node:assert/strict";
import { test } from "node:test";
import http from "node:http";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const CHILD = fileURLToPath(new URL("./exit-child.mjs", import.meta.url));
// Each child gets a throwaway home of its own, as every test process does.
const SETUP = fileURLToPath(new URL("../../../js/test/setup.mjs", import.meta.url));
const RUNS = 8;
// From the end of the script to process exit: the shared 6 s bound plus scheduling slack.
const EXIT_LIMIT_MS = 7500;

async function loads(load) {
  try {
    (await load()).dispose();
    return true;
  } catch {
    return false;
  }
}
const emoLoads = await loads(async () => (await import("../node.js")).Emo.load());
// shapes-node is needed only by the two-library case, which alone skips without it.
const shapesLoads = emoLoads && (await loads(async () => (await import("../../shapes-node/node.js")).Shapes.load()));
// Skipped locally when a model cannot load; in CI that is a failure.
const opts = emoLoads || process.env.CI ? {} : { skip: "native emo model unavailable" };
const twoOpts = shapesLoads || process.env.CI ? {} : { skip: "native shapes model unavailable" };

// Accepts every request and never answers, so each send is still pending when its process exits.
async function stalledServer() {
  const held = [];
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => held.push({ calls: JSON.parse(body).events.reduce((n, e) => n + (e.callCount ?? 0), 0), res }));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    held,
    endpoint: `http://127.0.0.1:${server.address().port}/api/v1/ingest`,
    close: async () => {
      for (const { res } of held) res.destroy();
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

function runChild(endpoint, mode) {
  return new Promise((resolve) => {
    const started = Date.now();
    const child = spawn(process.execPath, ["--import", SETUP, CHILD], {
      env: { ...process.env, EXIT_CASE: mode, CAPTURE_ENDPOINT: endpoint },
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("exit", (code, signal) => {
      const bodyDone = Number(/body-done (\d+)/.exec(stderr)?.[1] ?? started);
      resolve({ code, signal, stderr, ms: Date.now() - bodyDone });
    });
  });
}

async function check(mode, sendsPerRun, callsPerRun = sendsPerRun, maxSendsPerRun = sendsPerRun) {
  const server = await stalledServer();
  try {
    const results = await Promise.all(Array.from({ length: RUNS }, () => runChild(server.endpoint, mode)));
    for (const [i, r] of results.entries()) {
      assert.equal(r.signal, null, `${mode} run ${i} died by ${r.signal}: ${r.stderr.slice(-400)}`);
      assert.equal(r.code, 0, `${mode} run ${i} exited ${r.code}: ${r.stderr.slice(-400)}`);
      assert.ok(r.ms < EXIT_LIMIT_MS, `${mode} run ${i} took ${r.ms} ms to exit, past the bound`);
    }
    const sends = server.held.length;
    assert.ok(sends >= RUNS * sendsPerRun && sends <= RUNS * maxSendsPerRun, `${sends} sends reached the server before exit, expected ${RUNS * sendsPerRun} to ${RUNS * maxSendsPerRun}`);
    if (callsPerRun !== null) {
      const calls = server.held.reduce((n, h) => n + h.calls, 0);
      assert.equal(calls, RUNS * callsPerRun, `${calls} of ${RUNS * callsPerRun} calls were reported before exit`);
    }
  } finally {
    await server.close();
  }
}

test("a disposed model's send reaches the server before the process exits", opts, () => check("dispose", 1));
test("an undisposed model's usage is flushed at exit", opts, () => check("no-dispose", 1));
test("an earlier exit listener that calls process.exit() does not skip the wait", opts, () => check("early-exit-listener", 1));
// Call counts are not asserted: on Apple the two libraries share one stored turnstile without a lock between them.
test("two model libraries share one exit bound", twoOpts, () => check("two-libraries", 1, null, 2));
