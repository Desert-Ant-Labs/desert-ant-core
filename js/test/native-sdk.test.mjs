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
  const names = ["DAL_APP_ID"];
  const saved = Object.fromEntries(names.map((name) => [name, process.env[name]]));
  for (const name of names) delete process.env[name];
  try {
    // Built first, as a package's module scope does at import.
    const sdk = createNativeSdk({ here, packageName: "test", modelId: "test", coreName: "TestNode" });
    globalThis.__dalAppId = () => "com.acme.server";

    await assert.rejects(sdk.open(), "there is no native library here to load");
    assert.equal(process.env.DAL_APP_ID, "com.acme.server", "a function-valued global is called");
  } finally {
    delete globalThis.__dalAppId;
    for (const name of names) {
      if (saved[name] === undefined) delete process.env[name];
      else process.env[name] = saved[name];
    }
    fs.rmSync(here, { recursive: true, force: true });
  }
});

test("the license endpoint override reaches the native core", async () => {
  const here = fs.mkdtempSync(path.join(os.tmpdir(), "dal-native-sdk-"));
  fs.writeFileSync(path.join(here, "package.json"), JSON.stringify({ version: "0.0.0" }));
  const saved = process.env.DAL_LICENSE_ENDPOINT;
  delete process.env.DAL_LICENSE_ENDPOINT;
  try {
    const sdk = createNativeSdk({ here, packageName: "test", modelId: "test", coreName: "TestNode" });
    globalThis.__dalLicenseEndpoint = () => "http://127.0.0.1:9/global";

    await assert.rejects(sdk.open(), "there is no native library here to load");
    assert.equal(process.env.DAL_LICENSE_ENDPOINT, "http://127.0.0.1:9/global");
  } finally {
    delete globalThis.__dalLicenseEndpoint;
    if (saved === undefined) delete process.env.DAL_LICENSE_ENDPOINT;
    else process.env.DAL_LICENSE_ENDPOINT = saved;
    fs.rmSync(here, { recursive: true, force: true });
  }
});

test("an environment variable already set wins over the host global", async () => {
  const here = fs.mkdtempSync(path.join(os.tmpdir(), "dal-native-sdk-"));
  fs.writeFileSync(path.join(here, "package.json"), JSON.stringify({ version: "0.0.0" }));
  const saved = process.env.DAL_APP_ID;
  process.env.DAL_APP_ID = "com.acme.env";
  try {
    const sdk = createNativeSdk({ here, packageName: "test", modelId: "test", coreName: "TestNode" });
    globalThis.__dalAppId = "com.acme.global";
    await assert.rejects(sdk.open());
    assert.equal(process.env.DAL_APP_ID, "com.acme.env");
  } finally {
    delete globalThis.__dalAppId;
    if (saved === undefined) delete process.env.DAL_APP_ID;
    else process.env.DAL_APP_ID = saved;
    fs.rmSync(here, { recursive: true, force: true });
  }
});

test("once a native model has started, the bridge no longer writes the environment", async () => {
  // Core threads read the environment from then on, and a setenv racing their
  // getenv is a use-after-free on glibc.
  const here = fs.mkdtempSync(path.join(os.tmpdir(), "dal-native-sdk-"));
  fs.writeFileSync(path.join(here, "package.json"), JSON.stringify({ version: "0.0.0" }));
  const started = Symbol.for("desert-ant-labs.native-started");
  const saved = process.env.DAL_APP_ID;
  delete process.env.DAL_APP_ID;
  globalThis[started] = true;
  try {
    const sdk = createNativeSdk({ here, packageName: "test", modelId: "test", coreName: "TestNode" });
    globalThis.__dalAppId = "com.acme.late";
    await assert.rejects(sdk.open());
    assert.equal(process.env.DAL_APP_ID, undefined);
  } finally {
    delete globalThis[started];
    delete globalThis.__dalAppId;
    if (saved !== undefined) process.env.DAL_APP_ID = saved;
    fs.rmSync(here, { recursive: true, force: true });
  }
});

test("a host getter that throws does not fail the load", async () => {
  const here = fs.mkdtempSync(path.join(os.tmpdir(), "dal-native-sdk-"));
  fs.writeFileSync(path.join(here, "package.json"), JSON.stringify({ version: "0.0.0" }));
  globalThis.__dalAppId = () => {
    throw new Error("no request context");
  };
  try {
    const sdk = createNativeSdk({ here, packageName: "test", modelId: "test", coreName: "TestNode" });
    // It still rejects, but at the missing native library, not at the getter.
    await assert.rejects(sdk.open(), (error) => !String(error?.message).includes("no request context"));
  } finally {
    delete globalThis.__dalAppId;
    fs.rmSync(here, { recursive: true, force: true });
  }
});

test("the API key global no longer reaches the environment", async () => {
  const here = fs.mkdtempSync(path.join(os.tmpdir(), "dal-native-sdk-"));
  fs.writeFileSync(path.join(here, "package.json"), JSON.stringify({ version: "0.0.0" }));
  const saved = process.env.DAL_API_KEY;
  delete process.env.DAL_API_KEY;
  try {
    const sdk = createNativeSdk({ here, packageName: "test", modelId: "test", coreName: "TestNode" });
    globalThis.__dalApiKey = "dal_global";
    await assert.rejects(sdk.open());
    assert.equal(process.env.DAL_API_KEY, undefined);
  } finally {
    delete globalThis.__dalApiKey;
    if (saved !== undefined) process.env.DAL_API_KEY = saved;
    fs.rmSync(here, { recursive: true, force: true });
  }
});
