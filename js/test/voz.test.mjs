import test from "node:test";
import assert from "node:assert/strict";
import { configureOrt, decodeStepFor, createVozSessions, makeVozHost } from "../src/voz.js";

test("Voz keeps the measured runtime settings without importing a runtime", () => {
  assert.throws(() => configureOrt({}), /pass the onnxruntime-web module/);
  const ort = { env: { wasm: {} } };
  assert.equal(configureOrt({ ort, wasmDir: "/runtime/" }), ort);
  assert.equal(ort.env.wasm.numThreads, 1);
  assert.equal(ort.env.wasm.wasmPaths, "/runtime/");
});

test("WebNN and WebGPU retain their different decode widths", () => {
  const meta = { decode_lanes: 16, webgpu_decoder: { file: "wide.onnx", decode_lanes: 48 } };
  assert.deepEqual(decodeStepFor(meta, true), { file: "decoder.onnx", lanes: 16 });
  assert.deepEqual(decodeStepFor(meta, false), { file: "wide.onnx", lanes: 48 });
  assert.deepEqual(decodeStepFor({ decode_lanes: 16 }, false), { file: "decoder.onnx", lanes: 16 });
});

test("session creation preserves placements, external weights and disabled fusion", async () => {
  const calls = [];
  let released = false;
  const ort = { InferenceSession: { async create(bytes, options) {
    assert.equal(released, false);
    calls.push(options);
    return { bytes };
  } } };
  const weight = { path: "encoder.weights", data: new Uint8Array(4) };
  const webnn = [{ name: "webnn", deviceType: "npu" }];
  await createVozSessions({ ort, models: { encoder: new ArrayBuffer(1), decoder: new ArrayBuffer(1) },
    weights: { encoder: weight }, providers: { decoder: webnn }, onLoaded() { released = true; } });
  assert.deepEqual(calls[0].executionProviders, ["webgpu"]);
  assert.deepEqual(calls[1].executionProviders, webnn);
  assert.deepEqual(calls[0].externalData, [weight]);
  assert.ok(calls.every((call) => call.graphOptimizationLevel === "disabled"));
  assert.equal(released, true);
});

test("host awaits inference and forwards tensor types and dimensions", async () => {
  const tensor = { data: new Float32Array([1, 2]), dims: [1, 2], type: "float32" };
  const ort = { Tensor: class { constructor(type, data, dims) { Object.assign(this, { type, data, dims }); } } };
  const runtime = makeVozHost({ ort, sessions: { encoder: {
    inputNames: ["mel"], outputNames: ["enc_proj"], async run(feeds) {
      await Promise.resolve();
      assert.deepEqual(feeds.mel.data, tensor.data);
      return { enc_proj: tensor };
    },
  } } });
  assert.deepEqual(await runtime.host.run("encoder", { mel: tensor }), { enc_proj: tensor });
  assert.equal(runtime.timings.calls.encoder, 1);
  await assert.rejects(runtime.host.run("encoder", {}), /was not supplied/);
  await assert.rejects(runtime.host.run("missing", {}), /no session/);
  runtime.resetTimings();
  assert.equal(runtime.timings.calls.encoder, 0);
});
