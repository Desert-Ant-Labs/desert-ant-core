// The wasm seam: the JS half of the two generated contracts - the exports a core
// provides (`Sources/WasmBindings/Exports.swift`) and the host it is instantiated
// with (`Sources/JSHost/Host.swift`). The Swift halves are covered by the wasm
// build; here we pin the seam every model package resolves its core through.
import { test } from "node:test";
import assert from "node:assert/strict";
import { browserSetup } from "../src/litert.js";

/** Stand-in for what a Swift core exports (see dist/bridge-js.d.ts). */
function fakeCore() {
  return {
    modelInfo: () => ({ id: "shapes", sdkVersion: "1.0.0", artifact: "shapes.tflite", sidecars: [] }),
    create: () => 1,
    createSelfHosted: () => 2,
    isDownloaded: () => true,
    download: async () => true,
    run: async () => new Uint8Array(),
    runAudio: async () => new Uint8Array(),
    endCallGroup: () => {},
    destroy: () => {},
    flushTelemetry: async () => true,
  };
}

test("browserSetup instantiates with the host imports and returns both halves", async () => {
  const exports = fakeCore();
  let supplied;
  const init = async () => ({
    init: async (options) => {
      // The core is instantiated with the host contract it declared, before any
      // LiteRT session exists.
      supplied = options.getImports();
      return { exports };
    },
  });
  const core = await browserSetup({ init });
  assert.equal(core.exports, exports);
  assert.equal(typeof core.installHost, "function");
  assert.equal(typeof supplied.dalModelHost.run, "function");
  assert.equal(typeof supplied.dalModelHost.createSessionFromPath, "function");
  assert.equal(typeof supplied.dalModelHost.createSessionFromBytes, "function");
});

test("two cores on one page keep their own exports and their own host", async () => {
  const emo = fakeCore();
  const redact = fakeCore();
  const setup = (exports) =>
    browserSetup({ init: async () => ({ init: async () => ({ exports }) }) });
  const a = await setup(emo);
  const b = await setup(redact);
  assert.equal(a.exports, emo);
  assert.equal(b.exports, redact);
  // Nothing is keyed by name, so there is nothing for a second SDK to clobber.
  assert.notEqual(a.installHost, b.installHost);
});

test("nothing is installed on globalThis", async () => {
  const before = Object.keys(globalThis).filter((k) => k.startsWith("__Dal") || k.endsWith("Host"));
  await browserSetup({ init: async () => ({ init: async () => ({ exports: fakeCore() }) }) });
  const after = Object.keys(globalThis).filter((k) => k.startsWith("__Dal") || k.endsWith("Host"));
  assert.deepEqual(after, before);
});
