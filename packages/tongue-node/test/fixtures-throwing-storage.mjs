// Spawned by usage.test.js with no store installed: both storage globals throw on read; prints the post count.
for (const name of ["__dalUsageStore", "localStorage"]) {
  Object.defineProperty(globalThis, name, {
    configurable: true,
    get() {
      throw new Error("SecurityError");
    },
  });
}
const sent = [];
globalThis.fetch = (_url, init) => {
  sent.push(JSON.parse(init.body));
  return Promise.resolve({ ok: true });
};
const { UsageTurnstile } = await import("../dist/usage.js");
const turnstile = UsageTurnstile.create("9.9.9");
turnstile.record();
await turnstile.flushTelemetry();
console.log(JSON.stringify({ posts: sent.length }));
