// A shipped native server build reports usage despite the test switch or page flag; one process per case.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_DIR = path.join(HERE, "fixtures", "model");
const ENTRY = path.join(HERE, "..", "node.js");

/** Load, run once, flush, in a child process; resolves to the bodies the capture server got. */
async function postsFromChild({ env = {}, prelude = "" }) {
  const bodies = [];
  const server = http.createServer((req, res) => {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => {
      bodies.push(JSON.parse(data));
      res.writeHead(202).end();
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const script = `${prelude}
    const { Emo } = await import(${JSON.stringify(ENTRY)});
    const emo = await Emo.load({ directory: ${JSON.stringify(FIXTURE_DIR)} });
    await emo.suggestions("Pay my bills");
    await emo.flushTelemetry();
    emo.dispose();`;
  try {
    const child = spawn(process.execPath, ["--input-type=module", "-e", script], {
      env: {
        ...process.env,
        DAL_INGEST_ENDPOINT: `http://127.0.0.1:${server.address().port}/api/v1/ingest`,
        // A fresh turnstile namespace, so the load emits whatever this host sent before.
        DAL_APP_ID: `ai.desertant.emo.optout.${process.pid}.${Date.now()}.${Math.random()}`,
        ...env,
      },
      stdio: ["ignore", "inherit", "inherit"],
    });
    const code = await new Promise((resolve) => child.on("exit", resolve));
    assert.equal(code, 0, "the child process failed");
    return bodies;
  } finally {
    server.close();
  }
}

test("the shipped native ignores DAL_USAGE_DISABLED", async () => {
  const bodies = await postsFromChild({ env: { DAL_USAGE_DISABLED: "1" } });
  assert.equal(bodies.length, 1, "DAL_USAGE_DISABLED stopped a release native from reporting");
  assert.equal(bodies[0].platform, "server");
  assert.equal(bodies[0].events[0].callCount, 1);
});

test("the page's global does not opt a server out", async () => {
  const env = { DAL_USAGE_DISABLED: "" };
  const bodies = await postsFromChild({ env, prelude: "globalThis.__dalUsageDisabled = true;" });
  assert.equal(bodies.length, 1, "globalThis.__dalUsageDisabled stopped a server from reporting");
});

test("a bare load records no usage", async () => {
  const bodies = [];
  const server = http.createServer((req, res) => {
    req.resume();
    req.on("end", () => {
      bodies.push(req.url);
      res.writeHead(202).end();
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const script = `
      const { Emo } = await import(${JSON.stringify(ENTRY)});
      const emo = await Emo.load({ directory: ${JSON.stringify(FIXTURE_DIR)} });
      emo.isDownloaded();
      await emo.flushTelemetry();
      emo.dispose();`;
    const child = spawn(process.execPath, ["--input-type=module", "-e", script], {
      env: { ...process.env, DAL_USAGE_DISABLED: "", DAL_INGEST_ENDPOINT: `http://127.0.0.1:${server.address().port}/api/v1/ingest` },
      stdio: ["ignore", "inherit", "inherit"],
    });
    assert.equal(await new Promise((resolve) => child.on("exit", resolve)), 0);
    assert.deepEqual(bodies, [], "a load with no call posted usage");
  } finally {
    server.close();
  }
});
