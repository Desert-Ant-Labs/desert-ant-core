import { createPrivateKey, randomUUID, sign } from "node:crypto";
import { readFileSync } from "node:fs";

export const repo = new URL("../../../", import.meta.url);
export const vectors = JSON.parse(readFileSync(new URL("Tests/UsageTests/Resources/license_vectors.json", repo), "utf8"));
export const testKey = vectors.keys.find((key) => key.kid === "test-2");

const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");

export function signedToken(now = Date.now()) {
  const input = [
    encode({ alg: "ES256", kid: testKey.kid, typ: "dal-license+jwt" }),
    encode({
      v: 1,
      lid: randomUUID(),
      period: new Date(now).toISOString().slice(0, 7),
      periodEnd: new Date(now + 30 * 24 * 60 * 60 * 1000).toISOString(),
      iat: Math.floor(now / 1000) - 5,
    }),
  ].join(".");
  const key = createPrivateKey({ key: Buffer.from(testKey.privateKeyPkcs8, "base64"), format: "der", type: "pkcs8" });
  return `${input}.${sign("sha256", Buffer.from(input), { key, dsaEncoding: "ieee-p1363" }).toString("base64url")}`;
}

// A license that is in its period, so only the signature check can turn it down.
export function tamperedToken(now = Date.now()) {
  const [header, payload, signature] = signedToken(now).split(".");
  const changed = { ...JSON.parse(Buffer.from(payload, "base64url").toString()), lid: randomUUID() };
  return `${header}.${encode(changed)}.${signature}`;
}
