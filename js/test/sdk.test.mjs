// The shared model-SDK runtime: load / run / group / dispose, written once for
// both cores. Driven here through a fake core with the normalized shape, which
// is exactly what `wasmCore` and `createNativeSdk` produce - so this covers the
// logic every model package now inherits instead of hand-writing.
import { test } from "node:test";
import assert from "node:assert/strict";
import { LoadedModel, readyModel, wasmCore, createWasmSdk } from "../src/sdk.js";
import { FfiReader, FfiWriter } from "../src/ffi.js";

/** A core in the normalized shape, recording what it was asked to do. */
function fakeCore({ downloaded = false, failDownload = false } = {}) {
  const calls = [];
  let live = new Set();
  let next = 1;
  return {
    calls,
    isLive: (h) => live.has(h),
    create(cacheRoot, directory) {
      calls.push(["create", cacheRoot, directory]);
      const handle = next++;
      live.add(handle);
      return handle;
    },
    createSelfHosted(files) {
      calls.push(["createSelfHosted", Object.keys(files).sort()]);
      const handle = next++;
      live.add(handle);
      return handle;
    },
    isDownloaded: () => downloaded,
    async download(handle, onProgress) {
      calls.push(["download", handle]);
      if (failDownload) throw new Error("network is down");
      onProgress?.(0.5);
    },
    async run(handle, text, options, group, deviceId) {
      calls.push(["run", handle, text, options, group, deviceId]);
      return new FfiReader(new FfiWriter().str(`ran:${text}`).done());
    },
    destroy(handle) {
      calls.push(["destroy", handle]);
      live.delete(handle);
    },
    withCallGroup: async (body) => {
      const id = "group-1";
      calls.push(["groupStart", id]);
      try { return await body(id); } finally { calls.push(["groupEnd", id]); }
    },
  };
}

test("readyModel downloads before returning, so load() surfaces failures", async () => {
  const core = fakeCore();
  const progress = [];
  const model = await readyModel({
    core, packageName: "@x/y", handle: core.create("/cache", ""),
    onProgress: (f) => progress.push(f),
  });
  assert.deepEqual(core.calls.map((c) => c[0]), ["create", "download"]);
  assert.deepEqual(progress, [0.5, 1], "progress ends at 1");
  assert.ok(model instanceof LoadedModel);
});

test("a failed download disposes the handle and names the package", async () => {
  const core = fakeCore({ failDownload: true });
  const handle = core.create("/cache", "");
  await assert.rejects(
    () => readyModel({ core, packageName: "@desert-ant-labs/emo", handle }),
    // The package name comes from this layer, the reason from the core. It used
    // to say "model download failed" whatever had actually gone wrong.
    /@desert-ant-labs\/emo: .*network is down/s,
  );
  assert.equal(core.isLive(handle), false, "the handle is released, not leaked");
});

test("a null handle is a create failure, not a download attempt", async () => {
  const core = fakeCore();
  await assert.rejects(
    () => readyModel({ core, packageName: "@x/y", handle: 0 }),
    /@x\/y: failed to create the model/,
  );
  assert.deepEqual(core.calls, []);
});

test("run passes the options payload, group, and resolved device id through", async () => {
  const core = fakeCore();
  const model = await readyModel({ core, packageName: "@x/y", handle: core.create("/c", "") });
  const options = new FfiWriter().u32(3).done();
  const r = await model.run("hello", options, { group: 7, deviceId: () => "device-42" });
  assert.equal(r.str(), "ran:hello");
  const run = core.calls.find((c) => c[0] === "run");
  assert.deepEqual(run.slice(2), ["hello", options, "7", "device-42"]);
});

test("dispose releases the handle once and makes later calls throw", async () => {
  const core = fakeCore();
  const model = await readyModel({ core, packageName: "@x/y", handle: core.create("/c", "") });
  model.dispose();
  model.dispose(); // idempotent
  assert.equal(core.calls.filter((c) => c[0] === "destroy").length, 1);
  await assert.rejects(() => model.run("x", new Uint8Array()), /@x\/y: model disposed/);
});

test("withCallGroup opens and releases a group around the body", async () => {
  const core = fakeCore();
  const model = await readyModel({ core, packageName: "@x/y", handle: core.create("/c", "") });
  const seen = await model.withCallGroup(async (group) => {
    await model.run("a", new Uint8Array(), { group });
    return group;
  });
  assert.equal(seen, "group-1");
  assert.deepEqual(
    core.calls.map((c) => c[0]).filter((n) => n.startsWith("group") || n === "run"),
    ["groupStart", "run", "groupEnd"],
  );
});

test("wasmCore adapts the wasm ABI to the shared core shape", async () => {
  const payload = new FfiWriter().str("hi").done();
  const seen = [];
  const core = wasmCore({
    create: (...a) => { seen.push(["create", ...a]); return 5; },
    createSelfHosted: () => 6,
    isDownloaded: () => true,
    download: async () => true,
    run: async (...a) => { seen.push(["run", ...a]); return payload; },
    endCallGroup: (id) => seen.push(["endCallGroup", id]),
    destroy: (h) => seen.push(["destroy", h]),
  });
  core.create("/cache", "");
  // The input is a payload like the options and the result: one shape for text,
  // audio, video, anything a model takes.
  const reader = await core.run(5, new FfiWriter().str("hi").done(), null, null, null);
  assert.equal(reader.str(), "hi", "run yields a reader over the payload");
  await core.withCallGroup(async () => {});
  assert.deepEqual(seen.map((c) => c[0]), ["create", "run", "endCallGroup"]);
});

// The wasm SDK's two load paths, with a fake `#platform` seam and LiteRT.js.
function fakePlatform(exports, onInstall = () => {}) {
  return {
    setupCore: async () => ({ exports, installHost: onInstall }),
    defaultWasmDir: async () => "/wasm/",
    readModelSource: async (s) => s,
    defaultCacheRoot: async () => "/home/.cache",
  };
}

function fakeExports() {
  return {
    // The catalog facts come from the core itself, not from the package.
    modelInfo: () => ({ id: "y", sdkVersion: "1.0.0", artifact: "y.tflite", sidecars: ["y.json"] }),
    create: (cacheRoot, directory) => (cacheRoot === "/home/.cache" && directory === null ? 11 : 12),
    createSelfHosted: () => 13,
    isDownloaded: () => false,
    download: async () => true,
    run: async () => new FfiWriter().str("ok").done(),
    endCallGroup: () => {},
    destroy: () => {},
  };
}

const litert = {
  Tensor: class { delete() {} },
  loadLiteRt: async () => {},
  loadAndCompile: async () => ({ run: async () => ({}) }),
};

test("createWasmSdk downloads by default and adopts a directory when given one", async () => {
  let installed;
  const sdk = await createWasmSdk({
    platform: fakePlatform(fakeExports(), (host) => { installed = host; }),
    packageName: "@x/y",
  });
  const model = await sdk.open({ litert, litertWasmDir: "/wasm/" });
  assert.equal(model.isDownloaded(), false);
  // The LiteRT.js host is installed into the core's own import seam.
  assert.equal(typeof installed?.run, "function");
  const withDirectory = await sdk.open({ litert, litertWasmDir: "/wasm/", directory: "/models/y" });
  assert.ok(withDirectory instanceof LoadedModel);
});

test("createWasmSdk's modelBaseUrl path compiles the model and passes only sidecars", async () => {
  const exports = fakeExports();
  let sidecarNames;
  exports.createSelfHosted = (files) => { sidecarNames = Object.keys(files); return 13; };
  let compiled = 0;
  const orig = globalThis.fetch;
  globalThis.fetch = async () => ({ arrayBuffer: async () => new Uint8Array([1]).buffer });
  try {
    const sdk = await createWasmSdk({ platform: fakePlatform(exports), packageName: "@x/y" });
    await sdk.open({
      litert: { ...litert, loadAndCompile: async () => { compiled += 1; return { run: async () => ({}) }; } },
      litertWasmDir: "/wasm/",
      modelBaseUrl: "/assets/y",
    });
  } finally {
    globalThis.fetch = orig;
  }
  assert.equal(compiled, 1, "the host compiled the model itself");
  assert.deepEqual(sidecarNames, ["y.json"], "the artifact never crosses into the core");
});
