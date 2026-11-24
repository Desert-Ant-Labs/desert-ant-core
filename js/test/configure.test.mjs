import { test } from "node:test";
import assert from "node:assert/strict";
import { DesertAnt, registerCore } from "../index.js";
import { DesertAnt as NodeDesertAnt } from "../node.js";

test("a core registered before configure gets each key once it is set", () => {
  const seen = [];
  registerCore((settings) => seen.push(settings));
  assert.deepEqual(seen, []);
  DesertAnt.configure({ apiKey: "dal_a" });
  DesertAnt.configure({ apiKey: "dal_b" });
  assert.deepEqual(seen, [{ apiKey: "dal_a", deviceIdSecret: null }, { apiKey: "dal_b", deviceIdSecret: null }]);
});

test("a core registered after configure gets the current key at once", () => {
  DesertAnt.configure({ apiKey: "dal_c" });
  let got;
  registerCore((settings) => { got = settings; });
  assert.deepEqual(got, { apiKey: "dal_c", deviceIdSecret: null });
});

test("a core that fails to start is not kept", () => {
  assert.throws(() => registerCore(() => { throw new Error("no native library"); }));
  assert.doesNotThrow(() => DesertAnt.configure({ apiKey: "dal_d" }));
});

test("the browser and node entries share one store", () => {
  assert.equal(NodeDesertAnt, DesertAnt);
});

test("a key that is not a string is refused", () => {
  assert.throws(() => DesertAnt.configure({ apiKey: 42 }), TypeError);
  assert.throws(() => DesertAnt.configure({ apiKey: null }), TypeError);
  assert.throws(() => DesertAnt.configure({}), TypeError);
});

test("configure passes the device id secret, and a later call with only a key keeps it", () => {
  const seen = [];
  registerCore((settings) => seen.push(settings));
  seen.length = 0;
  DesertAnt.configure({ apiKey: "dal_e", deviceIdSecret: "0123456789abcdef0123456789abcdef" });
  DesertAnt.configure({ apiKey: "dal_f" });
  assert.deepEqual(seen, [
    { apiKey: "dal_e", deviceIdSecret: "0123456789abcdef0123456789abcdef" },
    { apiKey: "dal_f", deviceIdSecret: "0123456789abcdef0123456789abcdef" },
  ]);
});

test("a device id secret that is not a non-empty string is refused", () => {
  for (const deviceIdSecret of [42, null, "", "  "]) {
    assert.throws(() => DesertAnt.configure({ apiKey: "dal_e", deviceIdSecret }), TypeError);
  }
});

test("a page cannot set a device id secret", () => {
  globalThis.window = { document: {} };
  try {
    assert.throws(
      () => DesertAnt.configure({ apiKey: "dal_e", deviceIdSecret: "0123456789abcdef0123456789abcdef" }),
      /for servers/);
    assert.doesNotThrow(() => DesertAnt.configure({ apiKey: "dal_e" }));
  } finally {
    delete globalThis.window;
  }
});

test("a browser worker cannot set a device id secret", () => {
  const node = Object.getOwnPropertyDescriptor(globalThis, "process");
  Object.defineProperty(globalThis, "process", { value: undefined, configurable: true });
  let refused;
  let keyOnly;
  try {
    try {
      DesertAnt.configure({ apiKey: "dal_e", deviceIdSecret: "0123456789abcdef0123456789abcdef" });
    } catch (e) {
      refused = e;
    }
    try {
      DesertAnt.configure({ apiKey: "dal_e" });
      keyOnly = true;
    } catch {
      keyOnly = false;
    }
  } finally {
    Object.defineProperty(globalThis, "process", node);
  }
  assert.ok(refused instanceof TypeError && /for servers/.test(refused.message));
  assert.equal(keyOnly, true);
});

test("a native core without dal_configure loads without it", async () => {
  const { installConfigure } = await import("../src/native.js");
  const core = { func: () => { throw new Error("symbol not found"); } };
  assert.doesNotThrow(() => installConfigure(core));
});

test("a native core with dal_configure gets the settings", async () => {
  const { installConfigure } = await import("../src/native.js");
  const calls = [];
  let declared;
  const core = { func: (signature) => { declared = signature; return (apiKey) => calls.push(apiKey); } };
  DesertAnt.configure({ apiKey: "dal_native" });
  installConfigure(core);
  assert.equal(declared, "void dal_configure_device_id_secret(const char*)");
  assert.equal(calls.at(-2), "dal_native");
});

test("a native core without dal_configure_device_id_secret still gets the key", async () => {
  const { installConfigure } = await import("../src/native.js");
  const calls = [];
  const core = {
    func: (signature) => {
      if (signature.includes("device_id_secret")) throw new Error("symbol not found");
      return (apiKey) => calls.push(apiKey);
    },
  };
  DesertAnt.configure({ apiKey: "dal_old_core", deviceIdSecret: "0123456789abcdef0123456789abcdef" });
  installConfigure(core);
  assert.deepEqual(calls, ["dal_old_core"]);
});

const sharedState = () => globalThis[Symbol.for("desert-ant-labs.configure")];

test("a flush on one model flushes every core loaded in the process", async () => {
  const { registerFlush } = await import("../index.js");
  const { LoadedModel } = await import("../src/sdk.js");
  const flushed = [];
  const core = (name, sent) => ({ destroy() {}, flushLicenses: async () => { flushed.push(name); return sent; } });
  const emo = core("emo", true);
  const redact = core("redact", true);
  const gist = core("gist", false);
  registerFlush(emo.flushLicenses);
  registerFlush(redact.flushLicenses);
  try {
    const model = new LoadedModel({ core: emo, packageName: "@x/emo", handle: 1 });
    assert.equal(await model.flushLicenses(), true);
    assert.deepEqual(flushed.sort(), ["emo", "redact"], "each core once, this model's own too");

    registerFlush(gist.flushLicenses);
    assert.equal(await model.flushLicenses(), false, "one core with devices left makes the flush false");
  } finally {
    for (const one of [emo, redact, gist]) sharedState().flushes.delete(one.flushLicenses);
  }
});

test("a second copy of the package flushes the cores of the first", async () => {
  const { registerFlush } = await import("../index.js");
  const copy = await import("../src/configure.js?copy=2");
  let flushed = 0;
  const flush = async () => { flushed += 1; return true; };
  registerFlush(flush);
  try {
    assert.equal(await copy.flushCores(), true);
    assert.equal(flushed, 1);
  } finally {
    sharedState().flushes.delete(flush);
  }
});

test("a core that an older copy of the package loaded has no flush entry and is skipped", async () => {
  const { registerCore, flushCores } = await import("../index.js");
  const kept = sharedState().flushes;
  // What an older copy leaves: cores in the shared state, and no `flushes`.
  delete sharedState().flushes;
  let applied = 0;
  registerCore(() => { applied += 1; });
  try {
    let own = 0;
    assert.equal(await flushCores(async () => { own += 1; return true; }), true);
    assert.equal(own, 1);
    assert.equal(applied, 1, "the older core was configured and never called as a flush");
    assert.equal(await flushCores(), true);
  } finally {
    sharedState().flushes = kept;
  }
});

test("a core whose flush fails does not cut the other cores short", async () => {
  const { registerFlush, flushCores } = await import("../index.js");
  let finished = false;
  const broken = () => { throw new Error("no native library"); };
  const slow = async () => { await new Promise((done) => setTimeout(done, 20)); finished = true; return true; };
  registerFlush(broken);
  registerFlush(slow);
  try {
    await assert.rejects(flushCores(), /no native library/);
    assert.equal(finished, true);
  } finally {
    sharedState().flushes.delete(broken);
    sharedState().flushes.delete(slow);
  }
});
