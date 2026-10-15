// The license check a Linux native core makes through Node's crypto and a koffi callback.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { createRequire } from "node:module";
import {
  installLicenseVerifier,
  koffiCallbacksAreSafe,
  licenseVerifyCallback,
  verifyLicenseSignature,
} from "../src/native.js";

const vectors = JSON.parse(
  fs.readFileSync(new URL("../../Tests/UsageTests/Resources/license_vectors.json", import.meta.url), "utf8"),
);
const keys = Object.fromEntries(vectors.keys.map((key) => [key.kid, Buffer.from(key.publicKeyX963, "base64")]));

function token(name) {
  const [header, payload, signature] = vectors.tokens.find((vector) => vector.name === name).token.split(".");
  return {
    kid: JSON.parse(Buffer.from(header, "base64url").toString()).kid,
    message: Buffer.from(`${header}.${payload}`),
    signature: Buffer.from(signature, "base64url"),
  };
}

const verifies = (name, kid) => {
  const { kid: own, message, signature } = token(name);
  return verifyLicenseSignature(signature, message, keys[kid ?? own]);
};

let koffi;
try {
  koffi = createRequire(import.meta.url)("koffi");
} catch {}
const needsKoffi = { skip: !koffi && "koffi is not installed" };

test("the valid vector tokens verify under their kid", () => {
  assert.equal(verifies("valid"), true);
  assert.equal(verifies("valid-old-key"), true);
});

test("a bad signature, a tampered payload or the other key do not verify", () => {
  assert.equal(verifies("bad-signature"), false);
  assert.equal(verifies("tampered-payload"), false);
  const other = Object.keys(keys).find((kid) => kid !== token("valid").kid);
  assert.equal(verifies("valid", other), false);
});

test("malformed input is rejected rather than thrown", () => {
  const { kid, message, signature } = token("valid");
  const key = keys[kid];
  assert.equal(verifyLicenseSignature(signature.subarray(0, 63), message, key), false);
  assert.equal(verifyLicenseSignature(token("der-signature").signature, message, key), false);
  assert.equal(verifyLicenseSignature(signature, message, key.subarray(1)), false);
  const offCurve = Buffer.concat([Buffer.from([4]), Buffer.alloc(64, 1)]);
  assert.equal(verifyLicenseSignature(signature, message, offCurve), false);
});

test("the callback reads the bytes behind the pointers the core passes", needsKoffi, () => {
  const allocated = [];
  const pointer = (bytes) => {
    const memory = koffi.alloc("uint8_t", bytes.length);
    koffi.encode(memory, koffi.array("uint8_t", bytes.length), Array.from(bytes));
    allocated.push(memory);
    return memory;
  };
  const callback = licenseVerifyCallback(koffi);
  const call = (name) => {
    const { kid, message, signature } = token(name);
    const key = keys[kid];
    return callback(pointer(signature), signature.length, pointer(message), message.length, pointer(key), key.length);
  };
  try {
    assert.equal(call("valid"), 1);
    assert.equal(call("valid-old-key"), 1);
    assert.equal(call("tampered-payload"), 0);
    assert.equal(callback(null, 0, null, 0, null, 0), 0);
  } finally {
    for (const memory of allocated) koffi.free(memory);
  }
});

test("a Linux core gets the callback, and Node removes it before exit once no call is in flight", needsKoffi, () => {
  const installs = [];
  let inFlight = 1;
  const core = {
    func(name, result, parameters) {
      assert.deepEqual([name, result, parameters.length], ["dal_set_license_verifier", "int", 1]);
      return (pointer) => {
        installs.push(pointer);
        return pointer === null ? inFlight : 0;
      };
    },
  };
  const listeners = process.listeners("beforeExit");
  installLicenseVerifier(core, koffi, "linux");
  installLicenseVerifier(core, koffi, "linux");
  const added = process.listeners("beforeExit").filter((listener) => !listeners.includes(listener));
  try {
    assert.equal(installs.length, 2, "every core in the process gets the callback");
    assert.ok(installs.every((pointer) => pointer !== null));
    assert.equal(added.length, 2);

    added[0]();
    assert.equal(installs.at(-1), null);
    inFlight = 0;
    added[0]();
    assert.equal(installs.length, 4);
  } finally {
    for (const listener of added) process.removeListener("beforeExit", listener);
  }
});

test("a koffi before 2.16.3, or 3.1.2 on 3.x, gets no callback, so tokens go unverified", () => {
  for (const version of ["2.9.0", "2.15.3", "2.16.2", "3.0.0", "3.1.1", "1.99.99", undefined, "next"]) {
    assert.equal(koffiCallbacksAreSafe(version), false, String(version));
  }
  for (const version of ["2.16.3", "2.16.10", "2.17.0", "3.1.2", "3.3.2", "4.0.0"]) {
    assert.equal(koffiCallbacksAreSafe(version), true, version);
  }
  const listeners = process.listenerCount("beforeExit");
  installLicenseVerifier({ func: () => assert.fail("bound with an old koffi") }, { version: "2.16.2" }, "linux");
  assert.equal(process.listenerCount("beforeExit"), listeners);
});

test("other platforms and cores without the setter are left alone", needsKoffi, () => {
  const listeners = process.listenerCount("beforeExit");
  installLicenseVerifier({ func: () => assert.fail("bound off Linux") }, koffi, "darwin");
  installLicenseVerifier({ func: () => { throw new Error("symbol not found"); } }, koffi, "linux");
  assert.equal(process.listenerCount("beforeExit"), listeners);
});
