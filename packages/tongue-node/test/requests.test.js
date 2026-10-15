import { test } from "node:test";
import assert from "node:assert/strict";

import { Tongue } from "../dist/index.js";

test("a load and a detection send no requests, and flushTelemetry() resolves true", async () => {
  const realFetch = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (input) => {
    requests.push(String(input));
    throw new Error(`unexpected request to ${input}`);
  };
  try {
    const tongue = await Tongue.load();
    assert.equal(tongue.detect("kann ich das haben").language, "de");
    assert.equal(await tongue.flushTelemetry(), true);
    assert.deepEqual(requests, []);
  } finally {
    globalThis.fetch = realFetch;
  }
});
