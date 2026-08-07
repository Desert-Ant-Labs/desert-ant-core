import { test } from "node:test";
import assert from "node:assert/strict";
import {
  makeLiteRtHost,
  makeModelHostSeam,
  loadLiteRt,
  assertBrowserRuntime,
  fetchSelfHostedModel,
} from "../src/litert.js";

// A fake LiteRT.js: records compiled models and tensor lifecycle so we can
// assert the host marshals I/O and frees every tensor (LiteRT.js is manual).
function fakeLiteRt() {
  const deleted = [];
  class Tensor {
    constructor(data, dims) { this.data = data; this.dims = dims; this.deleted = false; }
    delete() { this.deleted = true; deleted.push(this); }
  }
  function makeOutput(name, floats) {
    const arr = Float32Array.from(floats);
    return {
      deleted: false,
      toTypedArray: () => arr,
      type: { dtype: "float32", layout: { dimensions: [floats.length] } },
      moveTo: async () => makeOutput(name, floats),
      delete() { this.deleted = true; deleted.push(this); },
    };
  }
  const loadAndCompile = async (bytes) => ({
    bytes,
    run: async (feeds) => {
      // echo: return one output "probs" = [sum of first input's data length]
      const first = Object.values(feeds)[0];
      return { probs: makeOutput("probs", [first.data.length]) };
    },
  });
  return { Tensor, loadAndCompile, deleted, loadLiteRt: async () => {} };
}

test("makeLiteRtHost creates a session and marshals + frees tensors", async () => {
  const lrt = fakeLiteRt();
  const { host } = makeLiteRtHost({
    accelerator: "wasm",
    loadAndCompile: lrt.loadAndCompile,
    Tensor: lrt.Tensor,
    readModelSource: async (s) => s, // bytes already
  });
  await host.createSessionFromBytes(new Uint8Array([1, 2, 3]));

  const input = { features: { data: new Uint8Array(new Float32Array([1, 2]).buffer), dims: [1, 2], type: "float32" } };
  const out = await host.run(input);

  assert.ok(out.probs, "returns named output");
  assert.equal(out.probs.type, "float32");
  assert.deepEqual(out.probs.dims, [1]);
  // Every tensor made (input) and produced (output) must be deleted.
  assert.ok(lrt.deleted.length >= 2, `all tensors freed (got ${lrt.deleted.length})`);
  assert.ok(lrt.deleted.every((t) => t.deleted), "each freed tensor marked deleted");
});

test("makeLiteRtHost setModel lets the modelBaseUrl path share run()", async () => {
  const lrt = fakeLiteRt();
  const { host, setModel } = makeLiteRtHost({
    loadAndCompile: lrt.loadAndCompile,
    Tensor: lrt.Tensor,
    readModelSource: async (s) => s,
  });
  setModel(await lrt.loadAndCompile(new Uint8Array([9])));
  const out = await host.run({
    x: { data: new Uint8Array(new Float32Array([1]).buffer), dims: [1], type: "float32" },
  });
  assert.ok(out.probs);
});

test("the host seam is late-bound, so a core can instantiate before LiteRT exists", async () => {
  const { imports, install } = makeModelHostSeam();
  await assert.rejects(
    () => imports.dalModelHost.run({}), /not installed yet/,
    "calling before install fails loudly rather than silently doing nothing");
  const lrt = fakeLiteRt();
  const { host } = makeLiteRtHost({
    loadAndCompile: lrt.loadAndCompile, Tensor: lrt.Tensor, readModelSource: async (s) => s,
  });
  install(host);
  await imports.dalModelHost.createSessionFromBytes(new Uint8Array([1]));
  const out = await imports.dalModelHost.run({
    x: { data: new Uint8Array(new Float32Array([1]).buffer), dims: [1], type: "float32" },
  });
  assert.ok(out.probs, "and forwards to the installed host afterwards");
});

test("loadLiteRt uses the injected module and initializes the runtime once", async () => {
  let loads = 0;
  const lrt = { loadAndCompile: async () => {}, Tensor: class {}, loadLiteRt: async () => { loads++; } };
  const mod = await loadLiteRt({ litert: lrt, defaultWasmDir: async () => "wasm/", packageName: "@x/y" });
  assert.equal(mod, lrt);
  await loadLiteRt({ litert: lrt, defaultWasmDir: async () => "wasm/", packageName: "@x/y" });
  assert.equal(loads, 1, "runtime load is memoized across calls");
});

test("separate core module copies still initialize one LiteRT runtime", async () => {
  const key = Symbol.for("ai.desertant.litert.state");
  delete globalThis[key];
  const first = await import("../src/litert.js?copy=first");
  const second = await import("../src/litert.js?copy=second");
  let loads = 0;
  const lrt = { loadLiteRt: async () => { loads++; } };
  const options = { litert: lrt, defaultWasmDir: async () => "wasm/", packageName: "@x/y" };
  await first.loadLiteRt(options);
  await second.loadLiteRt(options);
  assert.equal(loads, 1);
});

test("assertBrowserRuntime throws in plain Node, passes with injected litert", () => {
  assert.throws(() => assertBrowserRuntime({ packageName: "@desert-ant-labs/shapes" }), /native build/);
  assert.doesNotThrow(() => assertBrowserRuntime({ packageName: "@x/y", litert: {} }));
});

test("fetchSelfHostedModel fetches the catalog file names and normalizes the base", async () => {
  const seen = [];
  const orig = globalThis.fetch;
  globalThis.fetch = async (url) => {
    seen.push(url);
    const byte = url.endsWith(".tflite") ? 9 : 1;
    return { arrayBuffer: async () => new Uint8Array([byte, byte, byte]).buffer };
  };
  try {
    const { sidecars, modelBytes } = await fetchSelfHostedModel("/assets/shapes", {
      model: "shapes.tflite",
      sidecars: ["shapes_meta.json", "shapes_tokenizer.bin"],
    });
    assert.deepEqual(Array.from(modelBytes), [9, 9, 9]);
    // Sidecars come back keyed by catalog name, as bytes: the core decodes the
    // text ones itself, so the caller needs no per-file handling.
    assert.deepEqual(Object.keys(sidecars).sort(), ["shapes_meta.json", "shapes_tokenizer.bin"]);
    assert.ok(sidecars["shapes_meta.json"] instanceof Uint8Array);
    assert.deepEqual(seen.sort(), [
      "/assets/shapes/shapes.tflite",
      "/assets/shapes/shapes_meta.json",
      "/assets/shapes/shapes_tokenizer.bin",
    ]);
  } finally {
    globalThis.fetch = orig;
  }
});
