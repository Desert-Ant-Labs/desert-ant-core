import { test } from "node:test";
import assert from "node:assert/strict";

test("browser-safe entry exports the expected surface", async () => {
  const core = await import("../index.js");
  for (const name of [
    "FfiReader",
    "FfiWriter",
    "loadLiteRt",
    "assertBrowserRuntime",
    "makeLiteRtHost",
    "makeModelHostSeam",
    "fetchSelfHostedModel",
    "createWasmSdk",
    "readyModel",
    "wasmCore",
    "browserSetup",
    "browserWasmDir",
    "browserReadModelSource",
    "browserCacheRoot",
  ]) {
    assert.equal(typeof core[name], "function", `exports ${name}`);
  }
  assert.equal("installAudioHost" in core, false);
  assert.equal("decodeWav" in core, false);
});

test("node entry exports the native loader, and only that", async () => {
  const node = await import("../node.js");
  for (const name of [
    "createNativeSdk",
    "loadNative",
    "dalSymbols",
    "makeCallGroups",
    "FfiReader",
    "FfiWriter",
  ]) {
    assert.equal(typeof node[name], "function", `exports ${name}`);
  }
  assert.equal("installAudioHost" in node, false);
  // The `#platform` seam moved to ./platform-node.js: re-exporting it here put
  // koffi in every SSR bundle (see ssr-graph.test.mjs).
  for (const name of ["nodeSetup", "nodeWasmDir", "nodeReadModelSource", "nodeCacheRoot"]) {
    assert.equal(name in node, false, `node entry no longer exports ${name}`);
  }
});

test("platform-node entry exports the SSR node seam", async () => {
  const seam = await import("../platform-node.js");
  for (const name of ["nodeSetup", "nodeWasmDir", "nodeReadModelSource", "nodeCacheRoot"]) {
    assert.equal(typeof seam[name], "function", `exports ${name}`);
  }
  assert.equal("loadNative" in seam, false);
  assert.equal("createNativeSdk" in seam, false);
});

test("optional audio lives outside the text-model entries", async () => {
  const browser = await import("../audio.js");
  const node = await import("../audio-node.js");
  for (const name of ["installAudioHost", "decodeWav", "mixdownMono", "resampleLinear"]) {
    assert.equal(typeof browser[name], "function", `browser audio exports ${name}`);
    assert.equal(typeof node[name], "function", `node audio exports ${name}`);
  }
});

test("a model's ABI is generic apart from its own constructor", async () => {
  const { dalSymbols } = await import("../node.js");
  const emo = dalSymbols("emo");
  for (const name of ["isDownloaded", "download", "run", "destroy", "bufferFree"]) {
    assert.match(emo[name], /\bdal_[a-z_]+\(/, `${name} binds a generic dal_* symbol`);
  }
  assert.match(emo.run, /^void\* dal_run\(void\*, const char\*, const uint8_t\*, int,/);
  // The constructor is model-scoped, so two models can share one binary.
  assert.equal(emo.create, "void* emo_create(const char*, const char*, const char*)");
  assert.equal(dalSymbols("redact").create, "void* redact_create(const char*, const char*, const char*)");
});

test("loadNative reports a friendly error for an unsupported host", async () => {
  const { loadNative } = await import("../node.js");
  const core = loadNative({
    here: new URL("..", import.meta.url).pathname, // package dir (has package.json, no native/)
    packageName: "@desert-ant-labs/shapes",
    coreName: "ShapesNode",
    modelId: "shapes",
  });
  assert.throws(() => core.nativeDir(), /no prebuilt native for .*Supported server-side targets/s);
});

test("each package must name its own native library", async () => {
  const { loadNative } = await import("../node.js");
  assert.throws(
    () => loadNative({ here: ".", packageName: "@desert-ant-labs/shapes" }),
    /needs the native library's coreName/,
  );
});
