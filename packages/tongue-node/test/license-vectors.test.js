import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  deviceInstallId,
  licenseBackoff,
  licenseResponseAction,
  licenseRetryAfter,
  parseISO8601,
  parseLicenseToken,
  verifyLicenseToken,
} from "../dist/license.js";

import * as web from "../dist/platform.browser.js";
import * as node from "../dist/platform.node.js";

process.env.DAL_LICENSE_ENDPOINT ||= "http://127.0.0.1:9/api/v1";
process.env.DAL_STATE_DIR ||= new URL("../node_modules/.cache/tongue-test", import.meta.url).pathname;

const vectors = JSON.parse(
  readFileSync(new URL("../../../Tests/UsageTests/Resources/license_vectors.json", import.meta.url), "utf8"),
);
const keys = Object.fromEntries(vectors.keys.map((key) => [key.kid, key.publicKeyX963]));

const verifies = async (text, publicKeys = keys, canVerify = true) => {
  const token = parseLicenseToken(text);
  return token !== null && (await verifyLicenseToken(token, publicKeys, canVerify));
};

test("every vector token verifies as the vectors expect", async () => {
  assert.equal(vectors.tokens.length, 10);
  for (const { name, token, expect } of vectors.tokens) {
    assert.equal(await verifies(token), expect === "valid", name);
  }
});

test("a valid token carries the vector's payload, and fails under the other key", async () => {
  const valid = vectors.tokens.find((one) => one.name === "valid");
  const { header, payload } = parseLicenseToken(valid.token);
  assert.equal(header.kid, "test-2");
  for (const field of ["v", "lid", "period", "periodEnd", "iat"]) assert.equal(payload[field], valid.payload[field]);
  assert.equal(await verifies(valid.token, { "test-2": keys["test-1"] }), false);
  assert.equal(await verifies(valid.token, {}), false);
});

test("a host with no verifier still checks the header and the signature length", async () => {
  const token = (name) => vectors.tokens.find((one) => one.name === name).token;
  assert.equal(await verifies(token("bad-signature"), keys, false), true);
  assert.equal(await verifies(token("unknown-kid"), keys, false), true);
  for (const name of ["wrong-alg", "none-alg", "wrong-typ", "der-signature", "malformed"]) {
    assert.equal(await verifies(token(name), keys, false), false, name);
  }
});

test("the response rules match the vectors", () => {
  assert.ok(vectors.sdkResponseRules.length >= 10);
  for (const { status, dalErrorBody, action } of vectors.sdkResponseRules) {
    const body = dalErrorBody ? '{"error":"invalid_request","message":"bad"}' : "<html>Bad Gateway</html>";
    assert.equal(licenseResponseAction(status, body), action, `status ${status}, dal body ${dalErrorBody}`);
  }
  assert.equal(licenseResponseAction(400, '{"error":""}'), "retry");
  assert.equal(licenseResponseAction(422, '{"error":7}'), "retry");
});

test("the period ends in the vectors parse to their time", () => {
  for (const { serverTime, periodEnd } of vectors.periods) {
    assert.equal(parseISO8601(serverTime), Date.parse(serverTime), serverTime);
    assert.equal(parseISO8601(periodEnd), Date.parse(periodEnd), periodEnd);
  }
  for (const text of ["2026-11-07", "2026-11-07T00:00:00", "2026-11-07T00:00:00+01:00", "2026-13-07T00:00:00Z", "2026-11-07T00:00:00.Z"]) {
    assert.equal(parseISO8601(text), null, text);
  }
});

test("Retry-After and the backoff follow the Swift client", () => {
  assert.equal(licenseRetryAfter("60"), 60_000);
  assert.equal(licenseRetryAfter(" 5 "), 5000);
  assert.equal(licenseRetryAfter("999999999"), 6 * 60 * 60 * 1000);
  for (const raw of [null, "", "-1", "1.5", "Wed, 21 Oct 2026 07:28:00 GMT", "1 2"]) {
    assert.equal(licenseRetryAfter(raw), null, String(raw));
  }
  const top = (ceiling) => ceiling;
  assert.equal(licenseBackoff(0, null, top), 60_000);
  assert.equal(licenseBackoff(3, null, top), 480_000);
  assert.equal(licenseBackoff(40, null, top), 6 * 60 * 60 * 1000);
  assert.equal(licenseBackoff(0, 3_600_000, () => 0), 3_600_000);
  assert.equal(licenseBackoff(0, 1000, top), 60_000);
  for (let round = 0; round < 50; round += 1) {
    const delay = licenseBackoff(0, null);
    assert.ok(Number.isInteger(delay) && delay >= 0 && delay <= 60_000, String(delay));
  }
});

test("a device id gives the install id the Swift client gives", async () => {
  const secret = "0123456789abcdef0123456789abcdef";
  const base = await deviceInstallId("device-7", "server:acme-api", secret);
  assert.equal(base, "683119e6-c29e-877f-bb29-17ea7359b2e2");
  assert.equal(await deviceInstallId("dispositivo-ñ-7", "server:acme-api", secret), "18ad7c00-9138-8878-a365-2bb739f64c41");
  assert.equal(await deviceInstallId("device-7", "server:acme-api", null), "d7af4132-3cfb-8f76-a183-bd33d318ebd0");
  assert.equal(await deviceInstallId("device-7", "server:acme-api", null, null), "d7af4132-3cfb-8f76-a183-bd33d318ebd0");

  assert.notEqual(base, await deviceInstallId("device-8", "server:acme-api", secret));
  assert.notEqual(base, await deviceInstallId("device-7", "server:other-api", secret));
  assert.notEqual(base, await deviceInstallId("device-7", "server:acme-api", secret + "x"));
  assert.equal(base, await deviceInstallId("device-7", "server:Acme-API", secret));
  assert.equal(base, await deviceInstallId("device-7", " server:acme-api\n", secret));
  assert.notEqual(base, await deviceInstallId("Device-7", "server:acme-api", secret));
  assert.equal(base, await deviceInstallId("device-7", "server:acme-api", secret, "dal_one"));

  const first = await deviceInstallId("user-1", "server:node", null, "dal_one");
  assert.notEqual(first, await deviceInstallId("user-1", "server:node", null, "dal_two"));
  assert.equal(first, await deviceInstallId("user-1", "server:node", null, "dal_one"));
  assert.notEqual(
    await deviceInstallId("b", "server:a", secret),
    await deviceInstallId("ab", "server:", secret),
  );
});

test("WebCrypto and node:crypto give the same verdicts and hashes", async (t) => {
  const hasWebCrypto = globalThis.crypto?.subtle !== undefined;
  assert.equal(web.canVerifyLicense(), hasWebCrypto);
  if (!hasWebCrypto) {
    const valid = parseLicenseToken(vectors.tokens.find((one) => one.name === "valid").token);
    const key = new Uint8Array(Buffer.from(keys["test-2"], "base64"));
    assert.equal(await web.verifyLicenseSignature(valid.signature, valid.signingInput, key), false);
    return t.skip("this Node has no global WebCrypto");
  }
  let verified = 0;
  for (const { name, token } of vectors.tokens) {
    const parsed = parseLicenseToken(token);
    if (!parsed || parsed.signature.length !== 64) continue;
    for (const kid of Object.keys(keys)) {
      const key = new Uint8Array(Buffer.from(keys[kid], "base64"));
      const expected = await node.verifyLicenseSignature(parsed.signature, parsed.signingInput, key);
      assert.equal(await web.verifyLicenseSignature(parsed.signature, parsed.signingInput, key), expected, `${name} under ${kid}`);
      if (expected) verified += 1;
    }
  }
  const message = new TextEncoder().encode("dal-device-install/v1");
  const key = new TextEncoder().encode("0123456789abcdef0123456789abcdef");
  assert.deepEqual(await web.sha256(message), await node.sha256(message));
  assert.deepEqual(await web.hmacSha256(key, message), await node.hmacSha256(key, message));
  assert.ok(verified >= 2, String(verified));
});
