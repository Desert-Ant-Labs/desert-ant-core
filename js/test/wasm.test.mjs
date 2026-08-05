// The wasm export registry: the JS half of the model-agnostic WebAssembly ABI
// installed by Swift's WasmBindings (`globalThis.__DesertAntExports[modelId]`).
// The Swift half is covered by the wasm build; here we pin the seam every model
// package resolves its core through.
import { test } from "node:test";
import assert from "node:assert/strict";
import { wasmExports, browserSetup } from "../src/litert.js";

/** Stand-in for what a Swift core installs at start. */
function fakeCore(modelId) {
  const core = {
    create: () => 1,
    createSelfHosted: () => 2,
    isDownloaded: () => true,
    download: async () => true,
    run: async () => new Uint8Array(),
    endCallGroup: () => {},
    destroy: () => {},
    flushTelemetry: async () => true,
  };
  globalThis.__DesertAntExports = { ...(globalThis.__DesertAntExports ?? {}), [modelId]: core };
  return core;
}

test("wasmExports returns the core registered for a model id", () => {
  const core = fakeCore("emo");
  assert.equal(wasmExports("emo"), core);
});

test("two models register side by side instead of clobbering one global", () => {
  const emo = fakeCore("emo");
  const redact = fakeCore("redact");
  assert.equal(wasmExports("emo"), emo);
  assert.equal(wasmExports("redact"), redact);
});

test("wasmExports names the model when a core did not register", () => {
  assert.throws(() => wasmExports("nope"), /nope.*__DesertAntExports/s);
});

test("browserSetup seeds the host global, instantiates, and returns the core", async () => {
  delete globalThis.__ShapesHost;
  let initialized = 0;
  const init = async () => ({
    init: async () => {
      initialized += 1;
      fakeCore("shapes"); // the core installs its exports at start, as Swift does
    },
  });
  const core = await browserSetup({ hostGlobal: "__ShapesHost", modelId: "shapes", init });
  assert.equal(initialized, 1);
  // The host object must exist before the core starts: the wasm session looks it
  // up through this global.
  assert.equal(typeof globalThis.__ShapesHost, "object");
  assert.equal(core, wasmExports("shapes"));
  assert.equal(typeof core.run, "function");
});
