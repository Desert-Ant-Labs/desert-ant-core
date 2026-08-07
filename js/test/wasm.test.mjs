// The wasm seam: the JS half of the model-agnostic WebAssembly ABI that BridgeJS
// generates from the `@JS` entry points in a model's `Web/main.swift`. The Swift
// half is covered by the wasm build; here we pin the seam every model package
// resolves its core through.
import { test } from "node:test";
import assert from "node:assert/strict";
import { browserSetup } from "../src/litert.js";

/** Stand-in for what a Swift core exports (see dist/bridge-js.d.ts). */
function fakeCore() {
  return {
    create: () => 1,
    createSelfHosted: () => 2,
    isDownloaded: () => true,
    download: async () => true,
    run: async () => new Uint8Array(),
    endCallGroup: () => {},
    destroy: () => {},
    flushTelemetry: async () => true,
  };
}

test("browserSetup seeds the host global, instantiates, and returns the exports", async () => {
  delete globalThis.__ShapesHost;
  const exports = fakeCore();
  let initialized = 0;
  const init = async () => ({
    init: async () => {
      initialized += 1;
      // The host object must exist before the core starts: the wasm session
      // looks it up through this global.
      assert.equal(typeof globalThis.__ShapesHost, "object");
      return { exports };
    },
  });
  const core = await browserSetup({ hostGlobal: "__ShapesHost", init });
  assert.equal(initialized, 1);
  assert.equal(core, exports);
  assert.equal(typeof core.run, "function");
});

test("two cores on one page keep their own exports", async () => {
  const emo = fakeCore();
  const redact = fakeCore();
  const setup = (hostGlobal, exports) =>
    browserSetup({ hostGlobal, init: async () => ({ init: async () => ({ exports }) }) });
  assert.equal(await setup("__EmoHost", emo), emo);
  assert.equal(await setup("__RedactHost", redact), redact);
});

test("an existing host global is kept, not replaced", async () => {
  globalThis.__KeepHost = { marker: 1 };
  const exports = fakeCore();
  await browserSetup({
    hostGlobal: "__KeepHost",
    init: async () => ({ init: async () => ({ exports }) }),
  });
  assert.equal(globalThis.__KeepHost.marker, 1);
});
