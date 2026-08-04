// Proves the default entry (browser.js, the browser WebAssembly build) fails
// loudly and helpfully when someone calls Emo.load() in plain Node. LiteRT.js
// can only initialize in a browser or Web Worker, so server-side inference must
// go through the native build. We import the default entry in a child Node
// process (no DOM), call Emo.load, and assert it rejects with guidance pointing
// at `@desert-ant-labs/emo/native`. This is the Node-observable contract; the
// browser-only "install @litertjs/core" hint is covered by the browser example.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const pkgDir = path.resolve(here, "..");
const browserUrl = new URL("../browser.js", import.meta.url).href;

const child = `
const { Emo } = await import(${JSON.stringify(browserUrl)});
try {
  await Emo.load({});
  console.log("NO_ERROR");
} catch (e) {
  console.log("ERR:" + e.message);
}`;

test("default entry redirects to /native when Emo.load() runs in Node", () => {
  const res = spawnSync(process.execPath, ["--input-type=module", "-e", child],
    { cwd: pkgDir, encoding: "utf8", timeout: 120000 });
  const out = (res.stdout || "") + (res.stderr || "");
  assert.ok(out.includes("ERR:"), `expected a thrown error, got:\n${out}`);
  assert.ok(/@desert-ant-labs\/emo\/native/.test(out),
    `expected a redirect to the native build, got:\n${out}`);
});

test("default entry imports cleanly in Node (SSR-safe)", () => {
  const res = spawnSync(process.execPath,
    ["--input-type=module", "-e", `await import(${JSON.stringify(browserUrl)}); console.log("IMPORTED_OK");`],
    { cwd: pkgDir, encoding: "utf8", timeout: 120000 });
  const out = (res.stdout || "") + (res.stderr || "");
  assert.ok(out.includes("IMPORTED_OK"), `expected a clean import, got:\n${out}`);
});
