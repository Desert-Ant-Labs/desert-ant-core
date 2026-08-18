/**
 * Browser half of the platform split.
 *
 * A browser build must not contain `node:fs` and friends. `index.ts` used to
 * `await import("node:fs/promises")` inside `load()`, and bundlers resolve those
 * statically whether or not the branch can run: esbuild and webpack both failed
 * the build outright ("Could not resolve node:fs"), which ruled out Next.js,
 * Create React App and any webpack setup. Vite only survived by externalizing
 * them with a warning.
 *
 * The `browser` condition in package.json picks this file, so those specifiers
 * are not present in a browser build at all — while `import { Tongue } from
 * "@desert-ant-labs/tongue"` stays the single entry point on both platforms.
 */
import type { Metadata } from "./model.js";

/** Nothing to install: the browser turnstile persists in localStorage. */
export async function installUsageStorage(): Promise<void> {}

/**
 * Fetch the model relative to `from`.
 *
 * `from` is effectively required here. Without it the base is `.`, which
 * resolves against the *page* URL — on a single-page app that hits the history
 * fallback and returns index.html, and the old code then failed inside
 * `JSON.parse` with `Unexpected token '<'`, naming neither the model nor the
 * option that fixes it. The error below says both.
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
