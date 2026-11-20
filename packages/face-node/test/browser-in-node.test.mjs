import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const pkgDir = path.resolve(here, "..");
const browserUrl = new URL("../browser.js", import.meta.url).href;

const child = `
const { Face } = await import(${JSON.stringify(browserUrl)});
try {
  await Face.load({});
  console.log("NO_ERROR");
} catch (e) {
  console.log("ERR:" + e.message);
}`;

test("the default entry points to /native when Face.load() runs in Node", () => {
  const res = spawnSync(process.execPath, ["--input-type=module", "-e", child],
    { cwd: pkgDir, encoding: "utf8", timeout: 120000 });
  const out = (res.stdout || "") + (res.stderr || "");
  assert.ok(out.includes("ERR:"), `expected a thrown error, got:\n${out}`);
  assert.ok(/@desert-ant-labs\/face\/native/.test(out), `expected a pointer to the native build, got:\n${out}`);
});

test("the default entry imports cleanly in Node (SSR-safe)", () => {
  const res = spawnSync(process.execPath,
    ["--input-type=module", "-e", `await import(${JSON.stringify(browserUrl)}); console.log("IMPORTED_OK");`],
    { cwd: pkgDir, encoding: "utf8", timeout: 120000 });
  const out = (res.stdout || "") + (res.stderr || "");
  assert.ok(out.includes("IMPORTED_OK"), `expected a clean import, got:\n${out}`);
});
