import { test } from "node:test";
import assert from "node:assert/strict";
import {
  installLiteRtHost,
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

test("installLiteRtHost creates a session and marshals + frees tensors", async () => {
  const lrt = fakeLiteRt();
  installLiteRtHost({
    hostGlobal: "__TestHost",
    accelerator: "wasm",
    loadAndCompile: lrt.loadAndCompile,
    Tensor: lrt.Tensor,
    readModelSource: async (s) => s, // bytes already
  });
  const host = globalThis.__TestHost;
  await host.createSession(new Uint8Array([1, 2, 3]));

  const input = { features: { data: new Uint8Array(new Float32Array([1, 2]).buffer), dims: [1, 2], type: "float32" } };
  const out = await host.run(input);

  assert.ok(out.probs, "returns named output");
  assert.equal(out.probs.type, "float32");
  assert.deepEqual(out.probs.dims, [1]);
  // Every tensor made (input) and produced (output) must be deleted.
  assert.ok(lrt.deleted.length >= 2, `all tensors freed (got ${lrt.deleted.length})`);
  assert.ok(lrt.deleted.every((t) => t.deleted), "each freed tensor marked deleted");
  delete globalThis.__TestHost;
});

test("installLiteRtHost setModel lets the modelBaseUrl path share run()", async () => {
  const lrt = fakeLiteRt();
  const { setModel } = installLiteRtHost({
    hostGlobal: "__TestHost2",
    loadAndCompile: lrt.loadAndCompile,
    Tensor: lrt.Tensor,
    readModelSource: async (s) => s,
  });
  setModel(await lrt.loadAndCompile(new Uint8Array([9])));
  const out = await globalThis.__TestHost2.run({
    x: { data: new Uint8Array(new Float32Array([1]).buffer), dims: [1], type: "float32" },
  });
  assert.ok(out.probs);
  delete globalThis.__TestHost2;
});

test("loadLiteRt uses the injected module and initializes the runtime once", async () => {
  let loads = 0;
  const lrt = { loadAndCompile: async () => {}, Tensor: class {}, loadLiteRt: async () => { loads++; } };
  const mod = await loadLiteRt({ litert: lrt, defaultWasmDir: async () => "wasm/", packageName: "@x/y" });
  assert.equal(mod, lrt);
  await loadLiteRt({ litert: lrt, defaultWasmDir: async () => "wasm/", packageName: "@x/y" });
  assert.equal(loads, 1, "runtime load is memoized across calls");
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
