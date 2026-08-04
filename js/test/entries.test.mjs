import { test } from "node:test";
import assert from "node:assert/strict";

test("browser-safe entry exports the expected surface", async () => {
  const core = await import("../index.js");
  for (const name of [
    "FfiReader",
    "FfiWriter",
    "loadLiteRt",
    "assertBrowserRuntime",
    "installLiteRtHost",
    "fetchModelFrom",
    "browserSetup",
    "browserWasmDir",
    "browserReadModelSource",
    "browserCacheRoot",
  ]) {
    assert.equal(typeof core[name], "function", `exports ${name}`);
  }
});

test("node entry exports the native loader + node seam", async () => {
  const node = await import("../node.js");
  for (const name of [
    "loadNative",
    "nodeSetup",
    "nodeWasmDir",
    "nodeReadModelSource",
    "nodeCacheRoot",
    "FfiReader",
    "FfiWriter",
  ]) {
    assert.equal(typeof node[name], "function", `exports ${name}`);
  }
});

test("the native loader defaults to the one shared core and its generic ABI", async () => {
  const { DAL_SYMBOLS, DEFAULT_CORE_NAME } = await import("../node.js");
  // One library for every model: the model is a `modelId` argument, not a symbol.
  assert.equal(DEFAULT_CORE_NAME, "DesertAntNode");
  for (const name of [
    "create",
    "createFromFiles",
    "isDownloaded",
    "download",
    "run",
    "destroy",
    "bufferFree",
  ]) {
    assert.match(DAL_SYMBOLS[name], /\bdal_[a-z_]+\(/, `${name} binds a dal_* symbol`);
  }
  // dal_create/dal_run lead with the model id and carry the options payload.
  assert.equal(DAL_SYMBOLS.create, "void* dal_create(const char*, const char*, const char*)");
  assert.match(DAL_SYMBOLS.run, /^void\* dal_run\(void\*, const char\*, const uint8_t\*, int,/);
});

test("loadNative reports a friendly error for an unsupported host", async () => {
  const { loadNative } = await import("../node.js");
  const core = loadNative({
    here: new URL("..", import.meta.url).pathname, // package dir (has package.json, no native/)
    packageName: "@desert-ant-labs/shapes",
  });
  assert.throws(() => core.nativeDir(), /no prebuilt native for .*Supported server-side targets/s);
});
