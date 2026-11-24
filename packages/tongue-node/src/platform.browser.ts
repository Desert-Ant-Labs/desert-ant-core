/**
 * Browser half of the platform split.
 *
 * A browser build must not contain `node:fs` and friends: bundlers resolve a
 * dynamic `import("node:fs/promises")` statically whether or not the branch can
 * run, and esbuild and webpack fail the build ("Could not resolve node:fs").
 *
 * The `browser` condition in package.json picks this file, so those specifiers
 * are not present in a browser build at all, while `import { Tongue } from
 * "@desert-ant-labs/tongue"` stays the single entry point on both platforms.
 */
import type { Metadata } from "./model.js";

/**
 * Fetch the model relative to `from`.
 *
 * `from` is effectively required here. Without it the base is `.`, which
 * resolves against the *page* URL; on a single-page app that hits the history
 * fallback and returns index.html, which would fail inside `JSON.parse` with
 * `Unexpected token '<'`, naming neither the model nor the option that fixes
 * it. The error below says both.
 */
export async function readModel(
  from: string | undefined,
): Promise<{ metadata: Metadata; bytes: Uint8Array }> {
  const base = (from ?? ".").replace(/\/$/, "");
  const metadataURL = `${base}/tongue_meta.json`;
  const weightsURL = `${base}/tongue_int8.bin`;

  const [metadataResponse, weightsResponse] = await Promise.all([
    fetch(metadataURL),
    fetch(weightsURL),
  ]);
  for (const [url, response] of [
    [metadataURL, metadataResponse],
    [weightsURL, weightsResponse],
  ] as const) {
    if (!response.ok) {
      throw new Error(
        `tongue: could not load the model from ${url} (HTTP ${response.status}). ` +
          `In a browser the weights are served by your app, not bundled — copy ` +
          `tongue_int8.bin and tongue_meta.json somewhere public and pass ` +
          `Tongue.load({ from: "/that/path" }).`,
      );
    }
  }

  const text = await metadataResponse.text();
  let metadata: Metadata;
  try {
    metadata = JSON.parse(text) as Metadata;
  } catch {
    // Almost always the SPA history fallback returning index.html.
    const looksLikeHTML = text.trimStart().startsWith("<");
    throw new Error(
      `tongue: ${metadataURL} did not return JSON` +
        (looksLikeHTML
          ? " — it returned HTML, which usually means the path does not exist and your" +
            " server fell back to index.html."
          : ".") +
        ` Pass Tongue.load({ from: "/path/where/tongue_meta.json/lives" }).`,
    );
  }

  return { metadata, bytes: new Uint8Array(await weightsResponse.arrayBuffer()) };
}

// Absent on an insecure origin, where tokens then go unverified.
const subtle = (): SubtleCrypto | undefined => globalThis.crypto?.subtle;

export const canVerifyLicense = (): boolean => subtle() !== undefined;

export async function verifyLicenseSignature(
  signature: Uint8Array,
  message: Uint8Array,
  publicKey: Uint8Array,
): Promise<boolean> {
  const crypto = subtle();
  if (!crypto) return false;
  try {
    const key = await crypto.importKey(
      "raw",
      publicKey as BufferSource,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
    return await crypto.verify(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      signature as BufferSource,
      message as BufferSource,
    );
  } catch {
    return false;
  }
}

export async function sha256(message: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await subtle()!.digest("SHA-256", message as BufferSource));
}

export async function hmacSha256(key: Uint8Array, message: Uint8Array): Promise<Uint8Array> {
  const crypto = subtle()!;
  const imported = await crypto.importKey(
    "raw",
    key as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return new Uint8Array(await crypto.sign("HMAC", imported, message as BufferSource));
}

export const stateFile = (_onReplaced: () => void): null => null;

export async function randomUUID(): Promise<string> {
  const random = globalThis.crypto;
  if (typeof random?.randomUUID === "function") return random.randomUUID();
  const bytes = new Uint8Array(16);
  if (typeof random?.getRandomValues === "function") random.getRandomValues(bytes);
  else for (let index = 0; index < 16; index += 1) bytes[index] = Math.floor(Math.random() * 256);
  bytes[6] = (bytes[6]! & 0x0f) | 0x40;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join("-");
}
