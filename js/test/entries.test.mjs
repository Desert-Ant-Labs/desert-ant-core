import { test } from "node:test";
import assert from "node:assert/strict";

test("browser-safe entry exports the expected surface", async () => {
  const core = await import("../index.js");
  for (const name of [
    "FfiReader",
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
  for (const name of ["loadNative", "nodeSetup", "nodeWasmDir", "nodeReadModelSource", "nodeCacheRoot", "FfiReader"]) {
    assert.equal(typeof node[name], "function", `exports ${name}`);
  }
});

test("loadNative reports a friendly error for an unsupported host", async () => {
  const { loadNative } = await import("../node.js");
  const core = loadNative({
    here: new URL("..", import.meta.url).pathname, // package dir (has package.json, no native/)
    packageName: "@desert-ant-labs/shapes",
    coreName: "ShapesNode",
    symbols: { create: "void* shapes_create(const char*, const char*)" },
  });
  assert.throws(() => core.nativeDir(), /no prebuilt native for .*Supported server-side targets/s);
});
