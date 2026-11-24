import { test } from "node:test";
import assert from "node:assert/strict";

import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Tongue } from "../dist/index.js";

process.env.DAL_LICENSE_ENDPOINT ||= "http://127.0.0.1:9/api/v1";
process.env.DAL_STATE_DIR = mkdtempSync(join(tmpdir(), "tongue-state-"));

test("a load and a detection send license requests and nothing else, and the model never waits for them", async () => {
  const realFetch = globalThis.fetch;
  const requests = [];
  globalThis.fetch = (input, init) => {
    requests.push({ url: String(input), method: init?.method });
    return new Promise(() => {});
  };
  try {
    const tongue = await Tongue.load();
    const detection = tongue.detect("kann ich das haben");
    assert.equal(typeof detection.then, "undefined");
    assert.equal(detection.language, "de");
    assert.equal(tongue.detect("kann ich das haben", { topK: 1 }).candidates.length, 1);
    const deadline = Date.now() + 5000;
    while (requests.length === 0 && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 10));
    await new Promise((resolve) => setTimeout(resolve, 50));
    const endpoint = process.env.DAL_LICENSE_ENDPOINT.replace(/\/+$/, "");
    assert.deepEqual(requests, [{ url: `${endpoint}/license`, method: "POST" }]);
  } finally {
    globalThis.fetch = realFetch;
    rmSync(process.env.DAL_STATE_DIR, { recursive: true, force: true });
  }
});
