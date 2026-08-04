// Serves the repo and runs browser.html in headless Chromium, exercising the
// real on-device path: the Swift->wasm core + LiteRT.js inference on emo.tflite.
//
// The npm package does not bundle the model: the browser default (`Emo.load()`)
// downloads it from the Hugging Face Hub on first use and caches it (the browser
// fetch cache). This harness serves the repo over HTTP and lets that download
// hit the real Hub, so it needs network the first time.
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
    const p = url.pathname === "/" ? "/Examples/EmoWasmExample/browser.html" : url.pathname;
    const file = path.join(root, decodeURIComponent(p));
    const body = await readFile(file);
    res.writeHead(200, { "content-type": mime[path.extname(file)] ?? "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404); res.end("not found");
  }
});
await new Promise((r) => server.listen(8765, r));

const browser = await chromium.launch();
const page = await browser.newPage();
page.on("console", (m) => console.log("[page]", m.text()));

await page.goto("http://localhost:8765/");
const result = await page.waitForFunction(() => window.__result || window.__error, null, { timeout: 300000 });
const value = await result.jsonValue();
await browser.close();
server.close();

if (typeof value === "string") { console.error("browser error:\n" + value); process.exit(1); }
const emoji = value.suggestions.map((s) => s.emoji).join(" ");
console.log(`suggestions: ${emoji}`);
console.log(JSON.stringify(value.suggestions, null, 2));
console.log(`(${value.ms} ms in browser)`);
if (!value.suggestions.length) { console.error("no suggestions returned"); process.exit(1); }
