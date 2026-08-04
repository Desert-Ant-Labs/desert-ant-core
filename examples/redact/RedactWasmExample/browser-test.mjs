// Serves the repo and runs browser.html in headless Chromium.
import http from "node:http";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");

const mime = {
  ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
  ".wasm": "application/wasm", ".json": "application/json",
  ".bin": "application/octet-stream", ".tflite": "application/octet-stream",
};

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, "http://localhost");
    let p = url.pathname === "/" ? "/Examples/RedactWasmExample/browser.html" : url.pathname;
    if (p.startsWith("/node_modules/")) p = "/Examples/RedactWasmExample" + p;
    const file = path.join(root, decodeURIComponent(p));
    const body = await readFile(file);
    res.writeHead(200, { "content-type": mime[path.extname(file)] ?? "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404); res.end("not found");
  }
});
await new Promise(r => server.listen(8765, r));

const browser = await chromium.launch();
const page = await browser.newPage();
page.on("console", m => console.log("[page]", m.text()));
await page.goto("http://localhost:8765/");
const result = await page.waitForFunction(() => window.__result || window.__error, null, { timeout: 300000 });
const value = await result.jsonValue();
await browser.close();
server.close();

if (typeof value === "string") { console.error("browser error:\n" + value); process.exit(1); }
console.log("redacted: " + value.redactedText);
for (const item of value.items) {
  console.log(`  ${item.placeholder}  <-  "${item.original}"  (${item.label}, ${item.confidence.toFixed(2)})`);
}
console.log(`(${value.ms} ms in browser)`);
