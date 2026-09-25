// The per-event `context`: core's Sources/Usage/DeviceContext.swift rules on the
// hosts this port runs on. Kept out of usage_vectors.json on purpose: the Kotlin
// port sends no context, and that file is the contract the two ports share.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

import {
  BROWSER_NAMES,
  FORM_FACTORS,
  MAX_CONTEXT_BYTES,
  MAX_CONTEXT_VALUE_BYTES,
  UsageClient,
  UsageTurnstile,
  browserFacts,
  browserFormFactor,
  browserIdentity,
  browserOSName,
  defaultContextProvider,
  deviceContextDisabled,
  flagIsSet,
  languageRegion,
  nodeOSName,
  printableValue,
  sanitizeContext,
  usageDisabled,
} from "../dist/usage.js";

process.env.DAL_INGEST_ENDPOINT ??= "http://127.0.0.1:9/ingest";
// An opt-out in the calling shell would turn every provider here off.
delete process.env.DAL_USAGE_CONTEXT_DISABLED;
delete globalThis.__dalUsageContextDisabled;
delete process.env.DAL_APP_VERSION;
delete globalThis.__dalAppVersion;

const KEYS = [
  "appVersion", "osName", "osVersion", "deviceModel",
  "browserName", "browserVersion", "formFactor", "locale",
];
const bytes = (value) => new TextEncoder().encode(value).length;

/** A client whose sends land in `sends`, with `context` as its provider. */
function client(context, sends) {
  return new UsageClient({
    deviceId: "d",
    keyInBody: true,
    platform: "server",
    version: "9.9.9",
    windowMs: 86_400_000,
    now: () => 1700000000000,
    loadState: () => ({ lastActiveAt: 0, carryCallCount: 0 }),
    saveState: () => {},
    send: (body) => {
      sends.push(body);
    },
    context,
  });
}

/** Set globals and env vars for one test, and put them back after. */
async function withHost({ globals = {}, env = {} }, body) {
  const savedGlobals = Object.fromEntries(Object.keys(globals).map((k) => [k, globalThis[k]]));
  const savedEnv = Object.fromEntries(Object.keys(env).map((k) => [k, process.env[k]]));
  Object.assign(globalThis, globals);
  for (const [k, v] of Object.entries(env)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return await body();
  } finally {
    for (const [k, v] of Object.entries(savedGlobals)) {
      if (v === undefined) delete globalThis[k];
      else globalThis[k] = v;
    }
    for (const [k, v] of Object.entries(savedEnv)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

test("only the allowlisted keys survive", () => {
  assert.deepEqual(
    sanitizeContext({ osName: "iOS", deviceName: "Ana's iPhone", email: "a@b.c", locale: "pt-BR" }),
    { osName: "iOS", locale: "pt-BR" },
  );
});

test("a formFactor outside the vocabulary is dropped", () => {
  assert.deepEqual(sanitizeContext({ formFactor: "tv", osName: "tvOS" }), { osName: "tvOS" });
  for (const value of FORM_FACTORS) assert.equal(sanitizeContext({ formFactor: value }).formFactor, value);
});

test("values are printable, trimmed and cut on a character", () => {
  assert.equal(printableValue("  \u0007ab\u202Ec\u00AD\uFE0F\u{E0041}\uD800\n\t "), "abc");
  // Never splits a character: a decomposed é is three bytes and stays whole.
  assert.equal(printableValue("e\u0301".repeat(40)), "e\u0301".repeat(21));
  // Slicing for the segmenter comes after the filter, as core never slices.
  assert.equal(printableValue("\u200B".repeat(1100) + "abc"), "abc");
  assert.equal(bytes(printableValue("é".repeat(100))), MAX_CONTEXT_VALUE_BYTES);
  assert.equal(bytes(printableValue("語".repeat(100))), 63);
  assert.equal(bytes(printableValue("😀".repeat(100))), 64);
});

test("nothing left is no context", () => {
  assert.equal(sanitizeContext(undefined), undefined);
  assert.equal(sanitizeContext({}), undefined);
  assert.equal(sanitizeContext({ osName: " \u0000 ", other: "x" }), undefined);
  assert.equal(sanitizeContext({ osName: 42 }), undefined);
});

test("an oversized context is dropped and the event is still sent", () => {
  // Quotes escape to twice their length, which takes eight capped values past
  // the cap.
  const oversized = Object.fromEntries(KEYS.map((k) => [k, '"'.repeat(MAX_CONTEXT_VALUE_BYTES)]));
  oversized.formFactor = "mobile";
  assert.equal(sanitizeContext(oversized), undefined);

  const sends = [];
  const c = client(() => oversized, sends);
  c.start();
  c.flush();
  assert.equal(sends.length, 1);
  assert.equal(sends[0].events[0].context, undefined);
});

test("an oversized appVersion override is cut, not sent whole", async () => {
  await withHost({ globals: { __dalAppVersion: "9".repeat(10_000) } }, () => {
    const context = sanitizeContext(defaultContextProvider("web", false)());
    assert.equal(bytes(context.appVersion), MAX_CONTEXT_VALUE_BYTES);
    assert.ok(bytes(JSON.stringify(context)) <= MAX_CONTEXT_BYTES);
  });
});

test("the largest possible context fits", () => {
  const widest = "\u{10FFFF}".repeat(100);
  const context = sanitizeContext({ ...Object.fromEntries(KEYS.map((k) => [k, widest])), formFactor: "tablet" });
  assert.equal(Object.keys(context).length, 8);
  assert.ok(bytes(JSON.stringify(context)) <= MAX_CONTEXT_BYTES);
});

test("context rides after callCount, on the turnstile and on a delta", () => {
  const sends = [];
  const c = client(() => ({ osName: "Linux", hostname: "build-07" }), sends);
  c.start();
  c.recordCall(2);
  c.flush();
  c.recordCall();
  c.flush();
  assert.equal(
    JSON.stringify(sends[0].events[0]),
    '{"name":"load","deviceId":"d","callCount":2,"context":{"osName":"Linux"}}',
  );
  assert.deepEqual(sends[1].events[0].context, { osName: "Linux" });
});

test("a provider that throws costs the context, not the event", () => {
  const sends = [];
  const c = client(() => {
    throw new Error("host getter");
  }, sends);
  c.start();
  c.flush();
  assert.equal(sends.length, 1);
  assert.equal(sends[0].events[0].context, undefined);
});

test("a server sends only osName and appVersion", async () => {
  await withHost({ globals: { __dalAppVersion: "2.4.1" } }, () => {
    assert.deepEqual(defaultContextProvider("server", false)(), {
      appVersion: "2.4.1",
      osName: nodeOSName(process.platform),
    });
  });
});

test("a page's facts come from Client Hints, then the user agent", () => {
  assert.deepEqual(
    browserFacts({
      userAgent: chromeWinUA,
      language: "de-DE",
      maxTouchPoints: 0,
      userAgentData: { brands: chrome, mobile: false, platform: "Windows" },
    }),
    { osName: "Windows", browserName: "Chrome", browserVersion: "131", formFactor: "desktop", locale: "de-DE" },
  );
  assert.deepEqual(
    browserFacts({ userAgent: safariMacUA, language: "pt-BR", maxTouchPoints: 5 }),
    { osName: "iPadOS", browserName: "Safari", browserVersion: "18", formFactor: "tablet", locale: "pt-BR" },
  );
  assert.deepEqual(browserFacts(undefined), {});
  const odd = browserFacts({ userAgent: 42, language: 7, userAgentData: { brands: [null] } });
  assert.deepEqual(JSON.parse(JSON.stringify(odd)), {
    browserName: "Other", formFactor: "desktop",
  });
});

test("a page sends its facts unless the device id was supplied or it is a server", () => {
  const page = () =>
    browserFacts({
      userAgent: chromeWinUA,
      language: "de-DE",
      maxTouchPoints: 0,
      userAgentData: { brands: chrome, mobile: false, platform: "Windows" },
    });
  assert.deepEqual(defaultContextProvider("web", false, page)(), {
    osName: "Windows", browserName: "Chrome", browserVersion: "131", formFactor: "desktop", locale: "de-DE",
  });
  assert.deepEqual(defaultContextProvider("web", true, page)(), { osName: "Windows" });
  assert.deepEqual(defaultContextProvider("server", false, page)(), { osName: "Windows" });
});

test("a throwing appVersion getter costs appVersion, not the context", async () => {
  await withHost({ globals: { __dalAppVersion: () => { throw new Error("getter"); } } }, () => {
    assert.deepEqual(defaultContextProvider("server", false, () => ({ osName: "Linux" }))(), { osName: "Linux" });
  });
});

test("a malformed brand list falls back instead of losing the facts", () => {
  assert.deepEqual(browserIdentity([null], chromeWinUA), { name: "Chrome", version: "131" });
  assert.deepEqual(browserIdentity([{ brand: 7, version: null }, { brand: "Google Chrome", version: "131" }], chromeWinUA), {
    name: "Chrome", version: "131",
  });
});

test("the turnstile a host builds sends the server set, and nothing when opted out", async () => {
  const sent = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (_url, init) => {
    sent.push(JSON.parse(init.body));
    return Promise.resolve({ ok: true });
  };
  const store = () => {
    const values = new Map();
    return { get: (k) => values.get(k) ?? null, set: (k, v) => values.set(k, v) };
  };
  try {
    await withHost({ env: { DAL_USAGE_DISABLED: undefined, DAL_APP_VERSION: "3.0.0" } }, async () => {
      const turnstile = UsageTurnstile.create("9.9.9", store());
      turnstile.record();
      await turnstile.flushTelemetry();
      assert.deepEqual(sent[0].events[0].context, { appVersion: "3.0.0", osName: nodeOSName(process.platform) });

      await withHost({ env: { DAL_USAGE_CONTEXT_DISABLED: "1" } }, async () => {
        const quiet = UsageTurnstile.create("9.9.9", store());
        quiet.record();
        await quiet.flushTelemetry();
      });
      assert.equal(sent.length, 2);
      assert.equal(sent[1].events[0].context, undefined);
    });
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("the opt-outs share one truthiness rule", async () => {
  for (const value of ["1", "true", "yes", true, 1, -1, 0.5]) assert.equal(flagIsSet(value), true, String(value));
  for (const value of [undefined, null, "", "0", "false", false, 0, NaN, Infinity]) {
    assert.equal(flagIsSet(value), false, String(value));
  }

  await withHost({ globals: { __dalUsageContextDisabled: true } }, () => assert.equal(deviceContextDisabled(), true));
  await withHost({ globals: { __dalUsageContextDisabled: "false" } }, () => assert.equal(deviceContextDisabled(), false));
  await withHost({ globals: { __dalUsageContextDisabled: () => "1" } }, () => assert.equal(deviceContextDisabled(), true));
  await withHost({ env: { DAL_USAGE_CONTEXT_DISABLED: "0" } }, () => assert.equal(deviceContextDisabled(), false));
  await withHost({ env: { DAL_USAGE_CONTEXT_DISABLED: "1" } }, () => {
    assert.equal(deviceContextDisabled(), true);
    assert.equal(defaultContextProvider("server", false)(), undefined);
  });
});

// A page, as isBrowserOrigin sees one. The package's own usage module reads the
// global per call, so defining `document` for the length of a test is enough.
const page = { document: {} };

test("in a page the usage switch follows the same rule, and a throwing global reads as unset", async () => {
  const off = { DAL_USAGE_DISABLED: undefined };
  await withHost({ env: off, globals: page }, () => assert.equal(usageDisabled(), false));
  for (const value of [true, 1, "1", "true", () => true, () => "1", () => 1]) {
    await withHost({ env: off, globals: { ...page, __dalUsageDisabled: value } }, () =>
      assert.equal(usageDisabled(), true, String(value)),
    );
  }
  for (const value of [false, 0, NaN, "", "0", "false", () => false]) {
    await withHost({ env: off, globals: { ...page, __dalUsageDisabled: value } }, () =>
      assert.equal(usageDisabled(), false, String(value)),
    );
  }
  const throwing = () => {
    throw new Error("no consent manager yet");
  };
  await withHost({ env: off, globals: { ...page, __dalUsageDisabled: throwing } }, () =>
    assert.equal(usageDisabled(), false),
  );
  // An accessor whose getter throws, as a request-scoped host may define.
  Object.defineProperty(globalThis, "__dalUsageDisabled", { configurable: true, get: throwing });
  try {
    await withHost({ env: off, globals: page }, () => assert.equal(usageDisabled(), false));
  } finally {
    delete globalThis.__dalUsageDisabled;
  }
});

test("under Node the page's global is ignored: a server has no opt-out", async () => {
  const off = { DAL_USAGE_DISABLED: undefined };
  for (const value of [true, 1, "1", () => true]) {
    await withHost({ env: off, globals: { __dalUsageDisabled: value } }, () =>
      assert.equal(usageDisabled(), false, String(value)),
    );
  }
});

test("DAL_USAGE_DISABLED is a test switch, honored only under NODE_ENV=test", async () => {
  for (const value of ["1", "true"]) {
    await withHost({ env: { NODE_ENV: "test", DAL_USAGE_DISABLED: value } }, () =>
      assert.equal(usageDisabled(), true, value),
    );
  }
  for (const value of ["0", "false", ""]) {
    await withHost({ env: { NODE_ENV: "test", DAL_USAGE_DISABLED: value } }, () =>
      assert.equal(usageDisabled(), false, value),
    );
  }
  for (const nodeEnv of [undefined, "production", "development", ""]) {
    await withHost({ env: { NODE_ENV: nodeEnv, DAL_USAGE_DISABLED: "1" } }, () =>
      assert.equal(usageDisabled(), false, `NODE_ENV=${nodeEnv} honored the test switch`),
    );
  }
  // A throwing page global does not hide the test switch.
  const throwing = () => {
    throw new Error("no consent manager yet");
  };
  await withHost(
    { env: { NODE_ENV: "test", DAL_USAGE_DISABLED: "1" }, globals: { ...page, __dalUsageDisabled: throwing } },
    () => assert.equal(usageDisabled(), true, "a throwing global hid the environment"),
  );
});

test("locales are language and region only", () => {
  const cases = {
    "pt-BR": "pt-BR", en_US: "en-US", "zh-Hant-TW": "zh-TW", "es-419": "es-419", fr: "fr",
    "de-DE-u-co-phonebk": "de-DE", "en-US@rg=gbzzzz": "en-US", "sr-Latn": "sr",
  };
  for (const [tag, expected] of Object.entries(cases)) assert.equal(languageRegion(tag), expected, tag);
  for (const tag of ["", "*", undefined]) assert.equal(languageRegion(tag), undefined);
});

test("Node platforms map onto the same OS names", () => {
  assert.equal(nodeOSName("darwin"), "macOS");
  assert.equal(nodeOSName("linux"), "Linux");
  assert.equal(nodeOSName("win32"), "Windows");
  assert.equal(nodeOSName("freebsd"), "freebsd");
  assert.equal(nodeOSName(undefined), undefined);
});

const chromeMacUA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const chromeWinUA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const safariMacUA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15";
const chrome = [{ brand: "Google Chrome", version: "131" }, { brand: "Chromium", version: "131" }, { brand: "Not_A Brand", version: "24" }];

// The same rows as core's BrowserVocabularyTests, so the two describe a page alike.
const browserCases = [
  ["Chrome on macOS", chrome, "macOS", false, chromeMacUA, 0, "Chrome", "131", "macOS", "desktop"],
  ["Edge on Windows",
    [{ brand: "Microsoft Edge", version: "131" }, { brand: "Chromium", version: "131" }, { brand: "Not_A Brand", version: "24" }],
    "Windows", false, chromeWinUA + " Edg/131.0.0.0", 0, "Edge", "131", "Windows", "desktop"],
  ["Opera on Windows",
    [{ brand: "Opera", version: "115" }, { brand: "Chromium", version: "130" }, { brand: "Not?A_Brand", version: "99" }],
    "Windows", false, chromeWinUA + " OPR/115.0.0.0", 0, "Opera", "115", "Windows", "desktop"],
  ["Brave",
    [{ brand: "Brave", version: "131" }, { brand: "Chromium", version: "131" }, { brand: "Not_A Brand", version: "24" }],
    "Windows", false, chromeWinUA, 0, "Other", undefined, "Windows", "desktop"],
  ["Samsung Internet on an Android phone",
    [{ brand: "Samsung Internet", version: "27" }, { brand: "Chromium", version: "125" }, { brand: "Not.A/Brand", version: "24" }],
    "Android", true,
    "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/27.0 Chrome/125.0.0.0 Mobile Safari/537.36",
    0, "Samsung Internet", "27", "Android", "mobile"],
  ["Chrome on an Android tablet", chrome, "Android", false,
    "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    0, "Chrome", "131", "Android", "tablet"],
  ["Chrome on ChromeOS", chrome, "Chrome OS", false,
    "Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    0, "Chrome", "131", "ChromeOS", "desktop"],
  ["Safari on macOS", [], undefined, undefined, safariMacUA, 0, "Safari", "18", "macOS", "desktop"],
  ["Safari on an iPad", [], undefined, undefined, safariMacUA, 5, "Safari", "18", "iPadOS", "tablet"],
  ["Safari on an iPhone", [], undefined, undefined,
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Mobile/15E148 Safari/604.1",
    5, "Safari", "18", "iOS", "mobile"],
  ["Chrome on an iPhone", [], undefined, undefined,
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/131.0.6778.73 Mobile/15E148 Safari/604.1",
    5, "Chrome", "131", "iOS", "mobile"],
  ["Firefox on Linux", [], undefined, undefined,
    "Mozilla/5.0 (X11; Linux x86_64; rv:133.0) Gecko/20100101 Firefox/133.0", 0, "Firefox", "133", "Linux", "desktop"],
  ["Firefox on an Android phone", [], undefined, undefined,
    "Mozilla/5.0 (Android 14; Mobile; rv:133.0) Gecko/133.0 Firefox/133.0", 0, "Firefox", "133", "Android", "mobile"],
  ["Firefox on Windows", [], undefined, undefined,
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:133.0) Gecko/20100101 Firefox/133.0", 0, "Firefox", "133", "Windows", "desktop"],
  ["An iOS in-app web view", [], undefined, undefined,
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
    5, "Other", undefined, "iOS", "mobile"],
  ["Nothing to go on", [], undefined, undefined, "", 0, "Other", undefined, undefined, "desktop"],
];

test("a page is described in the shared vocabulary", () => {
  for (const [label, brands, hint, mobile, ua, touch, name, version, os, form] of browserCases) {
    const browser = browserIdentity(brands, ua);
    assert.equal(browser.name, name, `${label}: name`);
    assert.equal(browser.version, version, `${label}: version`);
    assert.ok(BROWSER_NAMES.has(browser.name), `${label}: vocabulary`);
    assert.equal(browserOSName(hint, ua, touch), os, `${label}: os`);
    assert.equal(browserFormFactor(ua, mobile, touch), form, `${label}: form factor`);
  }
});

test("the form factor is always one the ingest accepts", () => {
  const agents = [
    ...browserCases.map((c) => c[4]),
    "curl/8.4.0", "Mozilla/5.0 (PlayStation; PlayStation 5/2.26)", "Android", "iPad", "Mobile",
    "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0)", "\u0000", "Macintosh ".repeat(50),
  ];
  for (const ua of agents) {
    for (const touch of [0, 1, 5]) {
      for (const hint of [undefined, false, true]) {
        assert.ok(FORM_FACTORS.has(browserFormFactor(ua, hint, touch)), `${ua} ${touch} ${hint}`);
      }
    }
  }
});

test("a page's turnstile describes the host unless the host supplied another device's id", () => {
  // A child process: Node's facts are cached by the time any test here runs.
  const script = fileURLToPath(new URL("./fixtures-page-context.mjs", import.meta.url));
  const results = JSON.parse(execFileSync(process.execPath, [script], { encoding: "utf8" }));
  const full = { osName: "Windows", browserName: "Chrome", browserVersion: "131", formFactor: "desktop", locale: "de-DE" };
  assert.deepEqual(results.none, full);
  assert.deepEqual(results.persisted, full, "the persisted id is this device's own");
  assert.deepEqual(results.tenant, { osName: "Windows" });
});
