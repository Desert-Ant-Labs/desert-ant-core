// Node example for packages/emo-node. In Node the package's conditional exports
// resolve to the prebuilt native core (node.js), so inference runs natively
// server-side - no browser, no LiteRT.js needed. (The browser example,
// browser.html / `npm run browser-example`, exercises the WebAssembly +
// LiteRT.js path instead.)
// Enable DAL HTTP request logging. Set before importing Emo: static imports
// are hoisted, so we use a dynamic import below to guarantee ordering.
globalThis.__dalHttpDebug = true;
const { Emo } = await import("@desert-ant-labs/emo");

// Emo downloads, verifies (SHA-256), and caches the model from the Hub, then
// runs inference through the native core. First run fetches; later runs cache.
const emo = await Emo.load({});

const start = Date.now();
// `deviceId` attributes usage to a specific end-user device on multi-tenant
// hosts (a string, or a zero-arg function returning one). Omit for the host
// device. Collected per call, so it is safe under concurrency.
const suggestions = await emo.suggestions("Pay my bills", { limit: 3, deviceId: "user-42" });
console.log("suggestions:", suggestions.map((s) => s.emoji).join(" "));
console.log(JSON.stringify(suggestions, null, 2));
console.log(`(${Date.now() - start} ms)`);
emo.dispose();
