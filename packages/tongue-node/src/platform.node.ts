/**
 * Node half of the platform split. See platform.browser.ts for why this exists.
 *
 * Everything that touches a Node builtin lives here, and the `browser` condition
 * in package.json means a browser build never resolves this file — so `node:fs`
 * and friends cannot break a webpack or esbuild build the way they used to.
 */
import type { Metadata } from "./model.js";
import { setUsageStorage } from "./usage.js";

/**
 * Give the usage turnstile somewhere durable to keep its device id.
 *
 * Node has no `localStorage`, so without this every process minted a fresh id
 * and billing counts distinct devices — a server-side customer was billed once
 * per process start. Best-effort: an unwritable home directory just leaves the
 * turnstile in memory.
 */
export async function installUsageStorage(): Promise<void> {
  try {
    const [fs, path, os] = await Promise.all([
      import("node:fs"),
      import("node:path"),
      import("node:os"),
    ]);
    const file = path.join(os.homedir(), ".desert-ant", "usage.json");
    const read = (): Record<string, string> => {
      try {
        return JSON.parse(fs.readFileSync(file, "utf8")) as Record<string, string>;
      } catch {
        return {};
      }
    };
    setUsageStorage({
      get: (key) => read()[key] ?? null,
      set: (key, value) => {
        try {
          const all = read();
          all[key] = value;
          fs.mkdirSync(path.dirname(file), { recursive: true });
          fs.writeFileSync(file, JSON.stringify(all), "utf8");
        } catch {
          /* unwritable home; reporting is best-effort */
        }
      },
    });
  } catch {
    /* builtins unavailable */
  }
}

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
