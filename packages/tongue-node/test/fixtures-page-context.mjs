// Run in its own process by usage-context.test.js: a page, from the first
// import, so the cached host facts are the browser's. Prints one JSON line.
globalThis.document = {};
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: {
    userAgent:
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    language: "de-DE",
    maxTouchPoints: 0,
  },
});
delete process.env.DAL_USAGE_DISABLED;
delete process.env.DAL_USAGE_CONTEXT_DISABLED;
delete process.env.DAL_APP_VERSION;
delete process.env.DAL_DEVICE_ID;
const values = new Map([["ai.desertant.usage.deviceId", "persisted"]]);
const store = { get: (k) => values.get(k) ?? null, set: (k, v) => values.set(k, v) };
const sent = [];
globalThis.fetch = (_url, init) => {
  sent.push(JSON.parse(init.body));
  return Promise.resolve({ ok: true });
};
const { UsageTurnstile } = await import("../dist/usage.js");
const results = {};
for (const id of ["none", "persisted", "tenant"]) {
  if (id === "none") delete globalThis.__dalDeviceId;
  else globalThis.__dalDeviceId = id;
  for (const key of [...values.keys()]) if (key.endsWith(".state")) values.delete(key);
  const before = sent.length;
  const turnstile = UsageTurnstile.create("9.9.9", store);
  turnstile.record();
  await turnstile.flushTelemetry();
  if (sent.length !== before + 1) throw new Error(`${id}: expected one send, got ${sent.length - before}`);
  results[id] = sent.at(-1).events[0].context;
}
console.log(JSON.stringify(results));
