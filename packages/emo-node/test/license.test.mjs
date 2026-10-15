import assert from "node:assert/strict";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const FIXTURE_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures", "model");

const requests = [];
let answered = 0;
const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (chunk) => (body += chunk));
  req.on("end", () => {
    requests.push({ path: req.url, headers: req.headers, body });
    setTimeout(() => {
      answered += 1;
      res.writeHead(503, { "content-type": "application/json", "retry-after": "3600" });
      res.end(JSON.stringify({ error: "retry" }));
    }, 300);
  });
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
process.env.DAL_LICENSE_ENDPOINT = `http://127.0.0.1:${server.address().port}/api/v1`;
process.env.DAL_INGEST_ENDPOINT = `http://127.0.0.1:${server.address().port}/api/v1/ingest`;
process.env.DAL_APP_ID = "ai.desertant.emo.license-test";
delete process.env.DAL_API_KEY;

const { Emo } = await import("../node.js");
let emo;
let loadError;
try {
  emo = await Emo.load({ directory: FIXTURE_DIR });
} catch (e) {
  loadError = e;
}
const modelOpts = emo ? {} : { skip: `native model unavailable: ${String(loadError).slice(0, 120)}` };

test.after(() => {
  emo?.dispose();
  server.closeAllConnections();
  server.close();
});

test("a load sends one license grant and no usage, and flushTelemetry waits for its answer", modelOpts, async () => {
  assert.ok((await emo.suggestions("Pay my bills", { limit: 1, group: "retired" })).length > 0);
  await emo.flushTelemetry();

  assert.deepEqual(requests.map((r) => r.path), ["/api/v1/license"]);
  assert.equal(answered, 1, "flushTelemetry resolved before the grant was answered");
  assert.equal(requests[0].headers.authorization, undefined);
  const grant = JSON.parse(requests[0].body);
  assert.match(grant.installId, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
  assert.equal(grant.model, "emo");
  assert.equal(grant.sdk.name, "desert-ant-core");
  assert.equal(grant.platform, "server");
  assert.deepEqual(grant.app, { id: "ai.desertant.emo.license-test" });
  assert.equal(grant.key, undefined);
});
