// Telemetry smoke test against the real ingest API, server-side (native Node).
//
// Runs a redaction through the local packages/redact-node native build, then
// forces the debounced usage POST out and awaits it. With DAL_HTTP_DEBUG set,
// the Swift core logs the exact body posted and the response status + body.
//
// Run from the repo root:
//   mise run build:node-native redact   # once, to build the native core
//   node examples/redact/RedactWasmExample/telemetry-test.mjs

// Must be set before the model loads: the Swift core reads it at session
// creation to install the flush hooks, and the transport reads it to log.
process.env.DAL_HTTP_DEBUG = "1";

const { Redact } = await import("../../../packages/redact-node/node.js");

const redact = await Redact.load({});
const r = await redact.redaction("Hi, I'm Anna Kowalska, reach me at anna.k@example.com.");
console.log("redacted: " + r.redactedText);

// Force the usage turnstile to emit now (bypassing the debounce and the
// re-emit window) and wait for the HTTP send to finish before exiting.
console.log("flushing telemetry...");
await globalThis.__dalFlushTelemetry();
console.log("done");
