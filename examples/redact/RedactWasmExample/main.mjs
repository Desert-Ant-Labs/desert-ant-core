// Node example for packages/redact-node with local WebAssembly.
//
// Note: inference uses LiteRT.js (@litertjs/core), which is a browser runtime
// (it needs a DOM to load its Wasm). Run the browser example (browser.html /
// `npm run browser-example`) to exercise on-device inference; in plain Node the
// model session is unavailable and redaction throws. This file shows the API
// shape and doubles as a smoke test for the graceful "runtime absent" path.
import { Redact } from "@desert-ant-labs/redact";

// Redact downloads, verifies (SHA-256), and caches the model from the Hub;
// LiteRT.js runs inference in the browser. First run fetches; later runs cache.
const redact = await Redact.load({});

const text = process.argv.slice(2).join(" ") ||
  "Hi, I'm Anna Kowalska. Email me at anna.k@example.com or call +1 (555) 010-4477. " +
  "I live at 123 Any Street, Apt 4B, Seattle, WA 98109. Card: 4539 1488 0343 6467.";

const start = Date.now();
const r = await redact.redaction(text);
console.log("input:    " + text);
console.log("redacted: " + r.redactedText);
for (const item of r.items) {
  console.log(`  ${item.placeholder}  <-  "${item.original}"  (${item.label}, ${item.confidence.toFixed(2)})`);
}
console.log("restored: " + r.restore(r.redactedText));
console.log(`(${Date.now() - start} ms)`);
