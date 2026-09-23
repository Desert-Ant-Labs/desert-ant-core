// The native entry's host-identity bridge, without a native library: `open()`
// fails at the first native call, which comes after the bridge has run.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createNativeSdk } from "../src/native-sdk.js";

test("a host global set after the package loads still reaches the native core", async () => {
  const here = fs.mkdtempSync(path.join(os.tmpdir(), "dal-native-sdk-"));
  fs.writeFileSync(path.join(here, "package.json"), JSON.stringify({ version: "0.0.0" }));
  const names = ["DAL_APP_ID", "DAL_API_KEY", "DAL_DEVICE_ID"];
  const saved = Object.fromEntries(names.map((name) => [name, process.env[name]]));
  for (const name of names) delete process.env[name];
  try {
    // Built first, as a package's module scope does at import.
    const sdk = createNativeSdk({ here, packageName: "test", modelId: "test", coreName: "TestNode" });
    globalThis.__dalAppId = "com.acme.server";
    globalThis.__dalApiKey = () => "dal_test";
    globalThis.__dalDeviceId = "host-device";

    await assert.rejects(sdk.open(), "there is no native library here to load");
    assert.equal(process.env.DAL_APP_ID, "com.acme.server");
    assert.equal(process.env.DAL_API_KEY, "dal_test", "a function-valued global is called");
    assert.equal(process.env.DAL_DEVICE_ID, "host-device");
  } finally {
    delete globalThis.__dalAppId;
    delete globalThis.__dalApiKey;
    delete globalThis.__dalDeviceId;
    for (const name of names) {
      if (saved[name] === undefined) delete process.env[name];
      else process.env[name] = saved[name];
    }
    fs.rmSync(here, { recursive: true, force: true });
  }
});

test("the app version and the context flag reach the native core, a boolean flag included", async () => {
  const here = fs.mkdtempSync(path.join(os.tmpdir(), "dal-native-sdk-"));
  fs.writeFileSync(path.join(here, "package.json"), JSON.stringify({ version: "0.0.0" }));
  const names = ["DAL_APP_VERSION", "DAL_USAGE_CONTEXT_DISABLED"];
  const saved = Object.fromEntries(names.map((name) => [name, process.env[name]]));
  for (const name of names) delete process.env[name];
  try {
    const sdk = createNativeSdk({ here, packageName: "test", modelId: "test", coreName: "TestNode" });
    globalThis.__dalAppVersion = () => "2.4.1";
    globalThis.__dalUsageContextDisabled = true;

    await assert.rejects(sdk.open(), "there is no native library here to load");
    assert.equal(process.env.DAL_APP_VERSION, "2.4.1");
    assert.equal(process.env.DAL_USAGE_CONTEXT_DISABLED, "1");
  } finally {
    delete globalThis.__dalAppVersion;
    delete globalThis.__dalUsageContextDisabled;
    for (const name of names) {
      if (saved[name] === undefined) delete process.env[name];
      else process.env[name] = saved[name];
    }
    fs.rmSync(here, { recursive: true, force: true });
  }
});

test("an environment variable already set wins over the host global", async () => {
  const here = fs.mkdtempSync(path.join(os.tmpdir(), "dal-native-sdk-"));
  fs.writeFileSync(path.join(here, "package.json"), JSON.stringify({ version: "0.0.0" }));
  const saved = process.env.DAL_API_KEY;
  process.env.DAL_API_KEY = "dal_from_env";
  try {
    const sdk = createNativeSdk({ here, packageName: "test", modelId: "test", coreName: "TestNode" });
    globalThis.__dalApiKey = "dal_from_global";
    await assert.rejects(sdk.open());
    assert.equal(process.env.DAL_API_KEY, "dal_from_env");
  } finally {
    delete globalThis.__dalApiKey;
    if (saved === undefined) delete process.env.DAL_API_KEY;
    else process.env.DAL_API_KEY = saved;
    fs.rmSync(here, { recursive: true, force: true });
  }
});

test("once a native model has started, the bridge no longer writes the environment", async () => {
  // Core threads read the environment from then on, and a setenv racing their
  // getenv is a use-after-free on glibc.
  const here = fs.mkdtempSync(path.join(os.tmpdir(), "dal-native-sdk-"));
  fs.writeFileSync(path.join(here, "package.json"), JSON.stringify({ version: "0.0.0" }));
  const started = Symbol.for("desert-ant-labs.native-started");
  const saved = process.env.DAL_API_KEY;
  delete process.env.DAL_API_KEY;
  globalThis[started] = true;
  try {
    const sdk = createNativeSdk({ here, packageName: "test", modelId: "test", coreName: "TestNode" });
    globalThis.__dalApiKey = "dal_late";
    await assert.rejects(sdk.open());
    assert.equal(process.env.DAL_API_KEY, undefined);
  } finally {
    delete globalThis[started];
    delete globalThis.__dalApiKey;
    if (saved !== undefined) process.env.DAL_API_KEY = saved;
    fs.rmSync(here, { recursive: true, force: true });
  }
});

test("a host getter that throws does not fail the load", async () => {
  const here = fs.mkdtempSync(path.join(os.tmpdir(), "dal-native-sdk-"));
  fs.writeFileSync(path.join(here, "package.json"), JSON.stringify({ version: "0.0.0" }));
  globalThis.__dalDeviceId = () => {
    throw new Error("no request context");
  };
  try {
    const sdk = createNativeSdk({ here, packageName: "test", modelId: "test", coreName: "TestNode" });
    // It still rejects, but at the missing native library, not at the getter.
    await assert.rejects(sdk.open(), (error) => !String(error?.message).includes("no request context"));
  } finally {
    delete globalThis.__dalDeviceId;
    fs.rmSync(here, { recursive: true, force: true });
  }
});

test("the usage switch reaches the native core under the core's truthiness rule", async () => {
  const here = fs.mkdtempSync(path.join(os.tmpdir(), "dal-native-sdk-"));
  fs.writeFileSync(path.join(here, "package.json"), JSON.stringify({ version: "0.0.0" }));
  const saved = process.env.DAL_USAGE_DISABLED;
  const open = async (global, env) => {
    if (env === undefined) delete process.env.DAL_USAGE_DISABLED;
    else process.env.DAL_USAGE_DISABLED = env;
    globalThis.__dalUsageDisabled = global;
    const sdk = createNativeSdk({ here, packageName: "test", modelId: "test", coreName: "TestNode" });
    await assert.rejects(sdk.open(), "there is no native library here to load");
    return process.env.DAL_USAGE_DISABLED;
  };
  try {
    assert.equal(await open(true, undefined), "1");
    assert.equal(await open(() => "1", undefined), "1", "a function-valued global is called");
    assert.equal(await open("false", undefined), undefined, '"false" is off');
    assert.equal(await open(1, undefined), "1", "a non-zero number is a flag");
    assert.equal(await open(0, undefined), undefined, "0 is not");
    assert.equal(await open(NaN, undefined), undefined, "NaN is not");
    // Either side opts out: a global set turns on a flag the environment has off.
    assert.equal(await open(true, "0"), "1");
    assert.equal(await open(false, "1"), "1", "a global cannot clear the environment's opt-out");
    const throwing = () => {
      throw new Error("no consent manager yet");
    };
    assert.equal(await open(throwing, undefined), undefined, "a throwing global reads as unset");
  } finally {
    delete globalThis.__dalUsageDisabled;
    if (saved === undefined) delete process.env.DAL_USAGE_DISABLED;
    else process.env.DAL_USAGE_DISABLED = saved;
    fs.rmSync(here, { recursive: true, force: true });
  }
});
