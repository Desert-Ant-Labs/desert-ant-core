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

export const canVerifyLicense = (): boolean => true;

export async function verifyLicenseSignature(
  signature: Uint8Array,
  message: Uint8Array,
  publicKey: Uint8Array,
): Promise<boolean> {
  if (signature.length !== 64 || publicKey.length !== 65 || publicKey[0] !== 4) return false;
  try {
    const { createPublicKey, verify } = await import("node:crypto");
    const coordinate = (start: number) =>
      Buffer.from(publicKey.subarray(start, start + 32)).toString("base64url");
    const key = createPublicKey({
      key: { kty: "EC", crv: "P-256", x: coordinate(1), y: coordinate(33) },
      format: "jwk",
    });
    return verify("sha256", message, { key, dsaEncoding: "ieee-p1363" }, signature);
  } catch {
    return false;
  }
}

export async function sha256(message: Uint8Array): Promise<Uint8Array> {
  const { createHash } = await import("node:crypto");
  return new Uint8Array(createHash("sha256").update(message).digest());
}

export async function hmacSha256(key: Uint8Array, message: Uint8Array): Promise<Uint8Array> {
  const { createHmac } = await import("node:crypto");
  return new Uint8Array(createHmac("sha256", key).update(message).digest());
}

const STATE_FILE = "tongue.json";

export const stateLock = { staleMs: 10_000, waitMs: 2000, retryMs: 25 };

async function statePath(): Promise<string> {
  const { join } = await import("node:path");
  const { DAL_STATE_DIR, XDG_CONFIG_HOME, APPDATA } = process.env;
  if (DAL_STATE_DIR) return join(DAL_STATE_DIR, STATE_FILE);
  if (XDG_CONFIG_HOME) return join(XDG_CONFIG_HOME, "desert-ant", STATE_FILE);
  if (process.platform === "win32" && APPDATA) return join(APPDATA, "desert-ant", STATE_FILE);
  const { homedir } = await import("node:os");
  return join(homedir(), ".config", "desert-ant", STATE_FILE);
}

// A file that does not parse reads as empty, so the next write replaces it: a power loss can leave one.
async function readState(file: string): Promise<{ all: Record<string, unknown>; unreadable: boolean }> {
  const { readFile } = await import("node:fs/promises");
  let text: string;
  try {
    text = await readFile(file, "utf8");
  } catch (error) {
    if ((error as { code?: string }).code === "ENOENT") return { all: {}, unreadable: false };
    throw error;
  }
  let value: unknown = null;
  try {
    value = JSON.parse(text);
  } catch {}
  if (typeof value !== "object" || value === null || Array.isArray(value)) return { all: {}, unreadable: true };
  return { all: value as Record<string, unknown>, unreadable: false };
}

const pause = (ms: number): Promise<void> =>
  new Promise((resolve) => {
    const timer = setTimeout(resolve, ms);
    // A process that ends must not wait for a lock it no longer needs.
    timer.unref();
  });

const unique = (): string => `${process.pid}.${Math.random().toString(36).slice(2)}`;

const locked = (lock: string): Error =>
  Object.assign(new Error(`${lock} is held by another process`), { code: "ELOCKED" });

// The time on the volume that holds the file: on a shared volume it can differ from this host's by more than the stale time.
async function volumeTime(lock: string): Promise<number> {
  const { open, rm } = await import("node:fs/promises");
  const probe = `${lock}.${unique()}.probe`;
  const handle = await open(probe, "wx", 0o600);
  try {
    return (await handle.stat()).mtimeMs;
  } finally {
    await handle.close();
    await rm(probe, { force: true });
  }
}

interface HeldLock {
  owns(): Promise<boolean>;
  now(): Promise<number>;
}

// Two processes on one host share the file, so a write holds a lock file from its read to its rename.
async function withStateLock<T>(file: string, body: (held: HeldLock) => Promise<T>): Promise<T> {
  const { open, readFile, rm, stat } = await import("node:fs/promises");
  const lock = `${file}.lock`;
  const takeover = `${lock}.takeover`;
  const token = unique();
  const deadline = Date.now() + stateLock.waitMs;
  // Windows refuses to open a file that is being deleted, which is how a lock another process just released looks.
  const heldCodes = process.platform === "win32" ? ["EEXIST", "EISDIR", "EPERM", "EACCES", "EBUSY"] : ["EEXIST", "EISDIR"];
  let ahead: number | null = null;
  const now = async (): Promise<number> => Date.now() + (ahead ??= (await volumeTime(lock)) - Date.now());
  const isStale = async (path: string): Promise<boolean> => {
    const made = await stat(path).then((stats) => stats.mtimeMs, () => null);
    return made !== null && (await now()) - made > stateLock.staleMs;
  };
  while (true) {
    try {
      const handle = await open(lock, "wx", 0o600);
      try {
        await handle.writeFile(token);
      } finally {
        await handle.close();
      }
      break;
    } catch (error) {
      const code = (error as { code?: string }).code ?? "";
      if (!heldCodes.includes(code)) throw error;
      if (await isStale(lock)) {
        // One process at a time removes a dead lock, and looks again first: the lock it saw may be a new one by now.
        const mine = await open(takeover, "wx", 0o600).then((handle) => handle.close().then(() => true), () => false);
        if (mine) {
          try {
            if (await isStale(lock)) await rm(lock, { recursive: true, force: true });
          } finally {
            await rm(takeover, { force: true });
          }
          continue;
        }
        if (await isStale(takeover)) await rm(takeover, { recursive: true, force: true });
      }
      // A folder that takes no new file is not a held lock: the probe fails there, and the caller stops using the file.
      if (Date.now() >= deadline && code !== "EEXIST" && code !== "EISDIR") await volumeTime(lock);
      if (Date.now() >= deadline) throw locked(lock);
      await pause(stateLock.retryMs);
    }
  }
  // A holder that stalled past the stale time may have lost the lock, so it owns it only while its token is in it.
  const owns = (): Promise<boolean> => readFile(lock, "utf8").then((text) => text === token, () => false);
  try {
    return await body({ owns, now });
  } finally {
    if (await owns()) await rm(lock, { force: true });
  }
}

// A process that died between its write and its rename left a file that holds the API key.
async function removeOldTemporaries(file: string, now: number): Promise<void> {
  const { readdir, rm, stat } = await import("node:fs/promises");
  const { basename, dirname, join } = await import("node:path");
  for (const name of await readdir(dirname(file))) {
    if (!name.startsWith(`${basename(file)}.`) || !/\.\d+\.[a-z0-9]+\.(tmp|probe)$/.test(name)) continue;
    const path = join(dirname(file), name);
    const made = await stat(path).then((stats) => stats.mtimeMs, () => null);
    if (made !== null && now - made > stateLock.staleMs) await rm(path, { force: true });
  }
}

export function stateFile(onReplaced: () => void): {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, keepExisting: boolean): Promise<string>;
} {
  return {
    async get(key) {
      const value = (await readState(await statePath())).all[key];
      return typeof value === "string" ? value : null;
    },
    async put(key, value, keepExisting) {
      const { mkdir, open, rename, rm, utimes } = await import("node:fs/promises");
      const { dirname } = await import("node:path");
      const file = await statePath();
      await mkdir(dirname(file), { recursive: true, mode: 0o700 });
      return withStateLock(file, async (held) => {
        const { all, unreadable } = await readState(file);
        const existing = all[key];
        if (keepExisting && typeof existing === "string" && existing !== "") return existing;
        // Values this version does not know stay in the file.
        all[key] = value;
        const temporary = `${file}.${unique()}.tmp`;
        try {
          const handle = await open(temporary, "wx", 0o600);
          try {
            await handle.writeFile(JSON.stringify(all));
            // On disk before the rename, so a power loss leaves the old file or the new one, never an empty one.
            await handle.sync();
          } finally {
            await handle.close();
          }
          const stamp = new Date(await held.now());
          await utimes(`${file}.lock`, stamp, stamp).catch(() => {});
          if (!(await held.owns())) throw locked(`${file}.lock`);
          await rename(temporary, file);
        } catch (error) {
          await rm(temporary, { force: true });
          throw error;
        }
        await removeOldTemporaries(file, await held.now()).catch(() => {});
        if (unreadable) onReplaced();
        return value;
      });
    },
  };
}

export async function randomUUID(): Promise<string> {
  return (await import("node:crypto")).randomUUID();
}
