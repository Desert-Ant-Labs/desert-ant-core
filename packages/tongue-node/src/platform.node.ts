/**
 * Node half of the platform split. See platform.browser.ts for why this exists.
 *
 * Everything that touches a Node builtin lives here, and the `browser` condition
 * in package.json means a browser build never resolves this file, so `node:fs`
 * and friends cannot break a webpack or esbuild build.
 */
import type { Metadata } from "./model.js";

/**
 * Read the model from disk, defaulting to the package's own `dist/`.
 *
 * An `http`-prefixed `from` still goes over the network, so a Node process can
 * point at a CDN copy rather than the bundled one.
 */
export async function readModel(
  from: string | undefined,
): Promise<{ metadata: Metadata; bytes: Uint8Array }> {
  if (from?.startsWith("http")) {
    const base = from.replace(/\/$/, "");
    const [metadata, bytes] = await Promise.all([
      fetch(`${base}/tongue_meta.json`).then((r) => r.json() as Promise<Metadata>),
      fetch(`${base}/tongue_int8.bin`)
        .then((r) => r.arrayBuffer())
        .then((b) => new Uint8Array(b)),
    ]);
    return { metadata, bytes };
  }

  const { readFile } = await import("node:fs/promises");
  const { fileURLToPath } = await import("node:url");
  const { dirname, join } = await import("node:path");
  const base = from ?? dirname(fileURLToPath(import.meta.url));
  const metadata = JSON.parse(await readFile(join(base, "tongue_meta.json"), "utf8")) as Metadata;
  const bytes = new Uint8Array(await readFile(join(base, "tongue_int8.bin")));
  return { metadata, bytes };
}
