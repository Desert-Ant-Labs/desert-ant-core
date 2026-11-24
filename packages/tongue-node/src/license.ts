import {
  configuredApiKey,
  configuredDeviceIdSecret,
  flushCores,
  isNode,
  log,
  nodeProcess,
  registerFlush,
} from "./configure.js";
import type { LogLevel } from "./configure.js";
import { canVerifyLicense, hmacSha256, randomUUID, sha256, stateFile, verifyLicenseSignature } from "./platform.js";
import { SDK_VERSION } from "./version.js";

export const SDK_NAME = "desert-ant-core";
export const MODEL = "tongue";
export const MODEL_VERSION = "v1.0.0";

const DEFAULT_ENDPOINT = "https://events.desertant.com/api/v1";
const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;
const NETWORK_RETRY_MS = 5 * 60 * 1000;
const MIN_BACKOFF_MS = 60 * 1000;
const MAX_BACKOFF_MS = 6 * HOUR_MS;
const TERMINAL_WAIT_MS = DAY_MS;
const TIMEOUT_MS = 10 * 1000;
const DEVICE_REQUEST_HOLD_MS = 60 * 1000;
const DEVICE_CAPACITY = 200_000;
const DEVICE_QUEUE_LIMIT = 10_000;
const DEVICE_BATCH_ITEMS = 100;
const DEVICE_BATCH_WAIT_MS = 10 * 1000;
const DEVICE_SINGLE_GRANTS_MS = HOUR_MS;
const FLUSH_MS = 10 * 1000;
const INSTALL_ID_KEY = "ai.desertant.usage.deviceId";
const SERVER_GUIDE = "https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/docs/notes/server.md";

// Kid to uncompressed X9.63 P-256 public key, base64: the keys of events.desertant.com.
export const licensePublicKeys: Record<string, string> = {
  "prod-20261008": "BHkp0y3mP25qGm6pUkD52BxFH9NB2/px8QMf/fPemZH45msFUHbn+pVE0hgJ2QRmuou1QEFQru3zbUTQY2udOp8=",
};

const utf8 = (text: string): Uint8Array => new TextEncoder().encode(text);

export function base64Decode(text: string): Uint8Array | null {
  const bytes: number[] = [];
  let buffer = 0;
  let bits = 0;
  let padded = false;
  for (let index = 0; index < text.length; index += 1) {
    const char = text.charCodeAt(index);
    let value: number;
    if (char >= 0x41 && char <= 0x5a) value = char - 0x41;
    else if (char >= 0x61 && char <= 0x7a) value = char - 0x61 + 26;
    else if (char >= 0x30 && char <= 0x39) value = char - 0x30 + 52;
    else if (char === 0x2b || char === 0x2d) value = 62;
    else if (char === 0x2f || char === 0x5f) value = 63;
    else if (char === 0x3d) {
      padded = true;
      continue;
    } else return null;
    if (padded) return null;
    buffer = ((buffer << 6) | value) & 0xffff;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      bytes.push((buffer >> bits) & 0xff);
    }
  }
  return bits >= 6 ? null : Uint8Array.from(bytes);
}

export function parseISO8601(text: string): number | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?Z$/.exec(text);
  if (!match) return null;
  const [year, month, day, hour, minute, second] = match.slice(1, 7).map(Number) as [
    number, number, number, number, number, number,
  ];
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour >= 24 || minute >= 60 || second >= 61) return null;
  const millis = Number(((match[7] ?? "") + "000").slice(0, 3));
  const shifted = month <= 2 ? year - 1 : year;
  const era = Math.floor(shifted / 400);
  const yearOfEra = shifted - era * 400;
  const dayOfYear = Math.floor((153 * ((month + 9) % 12) + 2) / 5) + day - 1;
  const dayOfEra = yearOfEra * 365 + Math.floor(yearOfEra / 4) - Math.floor(yearOfEra / 100) + dayOfYear;
  const days = era * 146_097 + dayOfEra - 719_468;
  return ((days * 24 + hour) * 60 + minute) * 60_000 + second * 1000 + millis;
}

export interface LicenseToken {
  header: { alg: string; kid: string; typ: string };
  payload: { v: number; lid: string; period: string; periodEnd: string; iat: number };
  signingInput: Uint8Array;
  signature: Uint8Array;
}

function decodeJSON(bytes: Uint8Array | null): Record<string, unknown> | null {
  if (!bytes) return null;
  try {
    const value: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    return typeof value === "object" && value !== null && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

export function parseLicenseToken(token: string): LicenseToken | null {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const header = decodeJSON(base64Decode(parts[0]!));
  const payload = decodeJSON(base64Decode(parts[1]!));
  const signature = base64Decode(parts[2]!);
  if (!header || !payload || !signature) return null;
  const { alg, kid, typ } = header;
  const { v, lid, period, periodEnd, iat } = payload;
  if (typeof alg !== "string" || typeof kid !== "string" || typeof typ !== "string") return null;
  if (!Number.isInteger(v) || !Number.isInteger(iat)) return null;
  if (typeof lid !== "string" || typeof period !== "string" || typeof periodEnd !== "string") return null;
  return {
    header: { alg, kid, typ },
    payload: { v: v as number, lid, period, periodEnd, iat: iat as number },
    signingInput: utf8(`${parts[0]}.${parts[1]}`),
    signature,
  };
}

export async function verifyLicenseToken(
  token: LicenseToken,
  publicKeys: Record<string, string> = licensePublicKeys,
  canVerify: boolean = canVerifyLicense(),
): Promise<boolean> {
  if (token.header.alg !== "ES256" || token.header.typ !== "dal-license+jwt") return false;
  if (token.payload.v !== 1 || token.signature.length !== 64) return false;
  // No verifier on this host (an insecure web origin): the server holds the record of the license.
  if (!canVerify) return true;
  const encoded = Object.prototype.hasOwnProperty.call(publicKeys, token.header.kid) ? publicKeys[token.header.kid] : undefined;
  const publicKey = encoded === undefined ? null : base64Decode(encoded);
  if (!publicKey) return false;
  return verifyLicenseSignature(token.signature, token.signingInput, publicKey);
}

export type LicenseResponseAction = "done" | "terminal" | "retry" | "retry-network";

export function licenseResponseAction(status: number, body: string): LicenseResponseAction {
  if (status === 0) return "retry-network";
  if (status >= 200 && status < 300) return "done";
  if (status === 400 || status === 422) {
    const error = decodeJSON(utf8(body))?.error;
    if (typeof error === "string" && error !== "") return "terminal";
  }
  return "retry";
}

export function licenseRetryAfter(raw: string | null): number | null {
  if (raw === null) return null;
  const text = raw.trim();
  if (!/^[+-]?\d+$/.test(text)) return null;
  const seconds = Number(text);
  if (!(seconds >= 0)) return null;
  return seconds >= MAX_BACKOFF_MS / 1000 ? MAX_BACKOFF_MS : seconds * 1000;
}

export function licenseBackoff(
  attempt: number,
  retryAfter: number | null,
  jitter: (ceiling: number) => number = (ceiling) => Math.floor(Math.random() * (ceiling + 1)),
): number {
  const ceiling = Math.min(MAX_BACKOFF_MS, MIN_BACKOFF_MS * 2 ** Math.min(Math.max(attempt, 0), 16));
  const delay = jitter(ceiling);
  return retryAfter === null ? delay : Math.min(MAX_BACKOFF_MS, Math.max(delay, retryAfter));
}

export async function deviceInstallId(
  deviceId: string,
  app: string,
  secret: string | null,
  apiKey: string | null = null,
): Promise<string> {
  const parts = ["dal-device-install/v1", app.trim().toLowerCase(), deviceId];
  if (secret === null && apiKey !== null) parts.push(apiKey);
  const encoded = parts.map(utf8);
  const message = new Uint8Array(encoded.reduce((total, part) => total + 4 + part.length, 0));
  let offset = 0;
  for (const part of encoded) {
    new DataView(message.buffer).setUint32(offset, part.length);
    message.set(part, offset + 4);
    offset += 4 + part.length;
  }
  const hash = secret === null ? await sha256(message) : await hmacSha256(utf8(secret), message);
  const id = hash.slice(0, 16);
  id[6] = (id[6]! & 0x0f) | 0x80;
  id[8] = (id[8]! & 0x3f) | 0x80;
  const hex = Array.from(id, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join("-");
}

function hostString(name: string): string | null {
  try {
    const value = (globalThis as Record<string, unknown>)[name];
    const text: unknown = typeof value === "function" ? value() : value;
    return typeof text === "string" && text !== "" ? text : null;
  } catch {
    return null;
  }
}

function nodeEnvironment(name: string): string | null {
  if (!isNode()) return null;
  const value = nodeProcess()?.env?.[name];
  return typeof value === "string" && value !== "" ? value : null;
}

function defaultAppId(): string {
  const hostname = (globalThis as { location?: { hostname?: unknown } }).location?.hostname;
  if (typeof hostname === "string" && hostname !== "") return hostname;
  const title = nodeProcess()?.title;
  return typeof title === "string" && title !== "" ? title : "unknown";
}

export interface Identity {
  appId: string;
  apiKey: string | null;
  platform: "web" | "server";
  namespace: string;
}

const platform = (): "web" | "server" => (isNode() ? "server" : "web");

function identity(): Identity {
  const appId = nodeEnvironment("DAL_APP_ID") ?? hostString("__dalAppId") ?? defaultAppId();
  const apiKey = configuredApiKey();
  return { appId, apiKey, platform: platform(), namespace: apiKey ?? appId };
}

const endpoint = (): string =>
  hostString("__dalLicenseEndpoint") ?? nodeEnvironment("DAL_LICENSE_ENDPOINT") ?? DEFAULT_ENDPOINT;

interface KeyValueStore {
  getItem(key: string): unknown;
  setItem(key: string, value: string): unknown;
}

const memory = new Map<string, string>();

function hostStore(): KeyValueStore | null {
  const read = (name: string): KeyValueStore | null => {
    try {
      const value = (globalThis as Record<string, unknown>)[name];
      return typeof value === "object" && value !== null ? (value as KeyValueStore) : null;
    } catch {
      return null;
    }
  };
  // Node is never probed for localStorage: touching its global prints a warning, for a store that does not persist.
  return read("__dalUsageStore") ?? (isNode() ? null : read("localStorage"));
}

interface StateFile {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, keepExisting: boolean): Promise<string>;
}

let stateFileFailed = false;

// Node keeps the install id and the license in a file, so a new process is the same install.
function nodeStateFile(): StateFile | null {
  if (stateFileFailed || !isNode()) return null;
  const file: StateFile | null = stateFile(() =>
    warnOnce("stateFileReplaced", "The state file tongue.json was unreadable and was replaced, so this install has a new install id. The model keeps running."),
  );
  return file;
}

// Another process holds the lock: the write is tried again later, and the file is not given up.
const isLocked = (error: unknown): boolean => (error as { code?: unknown } | null)?.code === "ELOCKED";

function stateFileBroke(error: unknown): void {
  stateFileFailed = true;
  warnOnce(
    "stateFile",
    `The license cannot be kept on disk (${error instanceof Error ? error.message : String(error)}), so it is kept in memory and a new process asks for it again. Set DAL_STATE_DIR to a folder this process can write. The model keeps running.`,
  );
}

async function storageGet(key: string): Promise<string | null> {
  const store = hostStore();
  if (store) {
    try {
      const value = store.getItem(key);
      return typeof value === "string" ? value : null;
    } catch {
      return null;
    }
  }
  const file = nodeStateFile();
  if (file) {
    try {
      return await file.get(key);
    } catch (error) {
      stateFileBroke(error);
    }
  }
  return memory.get(key) ?? null;
}

// Resolves what the store holds after the write, and rejects while another process holds the state file's lock.
async function storagePut(key: string, value: string, keepExisting = false): Promise<string> {
  const store = hostStore();
  if (store) {
    try {
      const existing: unknown = keepExisting ? store.getItem(key) : null;
      if (typeof existing === "string" && existing !== "") return existing;
      store.setItem(key, value);
    } catch {}
    return value;
  }
  const file = nodeStateFile();
  if (file) {
    try {
      return await file.put(key, value, keepExisting);
    } catch (error) {
      if (isLocked(error)) throw error;
      stateFileBroke(error);
    }
  }
  const existing = keepExisting ? memory.get(key) : undefined;
  if (existing) return existing;
  memory.set(key, value);
  return value;
}

// Kept in memory: a store that drops writes would otherwise make a new install id, and a new license, for each request.
let installId: string | null = null;

async function currentInstallId(): Promise<string> {
  const stored = await storageGet(INSTALL_ID_KEY);
  installId = stored || (await storagePut(INSTALL_ID_KEY, installId ?? (await randomUUID()), true));
  return installId;
}

interface StoredLicense {
  token?: string;
  licenseId?: string;
  period?: string;
  activatedModels?: string[];
  refusedAt?: Record<string, number>;
  serverOffset: number;
}

// Its own key, apart from the record the shared core keeps under ai.desertant.license.
const recordKey = (namespace: string): string => `ai.desertant.tongue.license.${namespace}`;

function decodeRecord(raw: string | null): StoredLicense {
  const empty: StoredLicense = { serverOffset: 0 };
  if (raw === null) return empty;
  const value = decodeJSON(utf8(raw));
  if (!value) return empty;
  const { token, licenseId, period, activatedModels, refusedAt, serverOffset } = value;
  const text = (field: unknown) => field === undefined || typeof field === "string";
  if (!text(token) || !text(licenseId) || !text(period)) return empty;
  if (activatedModels !== undefined && !(Array.isArray(activatedModels) && activatedModels.every((one) => typeof one === "string"))) return empty;
  if (serverOffset !== undefined && !Number.isInteger(serverOffset)) return empty;
  if (refusedAt !== undefined) {
    if (typeof refusedAt !== "object" || refusedAt === null || Array.isArray(refusedAt)) return empty;
    if (!Object.values(refusedAt).every((time) => Number.isInteger(time))) return empty;
  }
  return {
    token: token as string | undefined,
    licenseId: licenseId as string | undefined,
    period: period as string | undefined,
    activatedModels: activatedModels as string[] | undefined,
    refusedAt: refusedAt === undefined ? undefined : { ...(refusedAt as Record<string, number>) },
    serverOffset: (serverOffset as number | undefined) ?? 0,
  };
}

const encodeRecord = (license: StoredLicense): string => JSON.stringify(license);

function isRefused(license: StoredLicense, time: number): boolean {
  const refused = license.refusedAt?.[MODEL];
  return refused !== undefined && time >= refused && time - refused < TERMINAL_WAIT_MS;
}

function refuse(license: StoredLicense, time: number): void {
  license.refusedAt = { ...license.refusedAt, [MODEL]: time };
}

function dropEndedRefusals(license: StoredLicense, time: number): void {
  if (!license.refusedAt) return;
  const waits = Object.entries(license.refusedAt).filter(
    ([, refused]) => time >= refused && time - refused < TERMINAL_WAIT_MS,
  );
  license.refusedAt = waits.length === 0 ? undefined : Object.fromEntries(waits);
}

const unsaved = new Map<string, { json: string; stored: string | null }>();

// The copy in memory serves only while the store holds what it held when the write failed.
async function readRecord(key: string): Promise<string | null> {
  const kept = await storageGet(key);
  const copy = unsaved.get(key);
  if (!copy) return kept;
  if (kept === copy.stored) return copy.json;
  unsaved.delete(key);
  return kept;
}

async function saveRecord(key: string, license: StoredLicense): Promise<void> {
  const json = encodeRecord(license);
  await storagePut(key, json).catch(() => {});
  const kept = await storageGet(key);
  if (kept === json) unsaved.delete(key);
  else unsaved.set(key, { json, stored: kept });
}

async function isValid(license: StoredLicense): Promise<boolean> {
  const token = license.token === undefined ? null : parseLicenseToken(license.token);
  if (!token || !(await verifyLicenseToken(token))) return false;
  const end = parseISO8601(token.payload.periodEnd);
  if (end === null) return false;
  const serverNow = Date.now() + license.serverOffset;
  return Math.trunc(serverNow / 1000) >= token.payload.iat && serverNow < end;
}

// Other tabs write this record too, so a write starts from what is stored now.
async function replaceUnlessValid(
  who: Identity,
  change: (license: StoredLicense) => void,
): Promise<{ license: StoredLicense; valid: boolean }> {
  const key = recordKey(who.namespace);
  while (true) {
    const raw = await readRecord(key);
    const stored = decodeRecord(raw);
    if (await isValid(stored)) return { license: stored, valid: true };
    const license: StoredLicense = { refusedAt: stored.refusedAt, serverOffset: stored.serverOffset };
    change(license);
    dropEndedRefusals(license, Date.now());
    if ((await readRecord(key)) !== raw) continue;
    if (encodeRecord(license) !== encodeRecord(stored)) await saveRecord(key, license);
    return { license, valid: false };
  }
}

export interface Reply {
  status: number;
  retryAfter: string | null;
  body: string;
}

async function post(path: string, payload: unknown): Promise<Reply | null> {
  let signal: AbortSignal | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  if (typeof AbortSignal !== "undefined" && typeof AbortSignal.timeout === "function") {
    signal = AbortSignal.timeout(TIMEOUT_MS);
  } else if (typeof AbortController !== "undefined") {
    const controller = new AbortController();
    timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
    (timer as { unref?: () => void }).unref?.();
    signal = controller.signal;
  }
  try {
    const response = await globalThis.fetch(`${endpoint().replace(/\/+$/, "")}/${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal,
    });
    return { status: response.status, retryAfter: response.headers.get("retry-after"), body: await response.text() };
  } catch {
    return null;
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}

function grantRequest(installId: string, who: Identity): Record<string, unknown> {
  return {
    installId,
    model: MODEL,
    modelVersion: MODEL_VERSION,
    sdk: { name: SDK_NAME, version: SDK_VERSION },
    platform: who.platform,
    app: { id: who.appId },
    ...(who.apiKey === null ? {} : { key: who.apiKey }),
  };
}

function grantedToken(body: string): { token: string; serverTime: number | null } | null {
  const reply = decodeJSON(utf8(body));
  if (!reply || typeof reply.token !== "string") return null;
  if (reply.serverTime !== undefined && reply.serverTime !== null && typeof reply.serverTime !== "string") return null;
  return { token: reply.token, serverTime: typeof reply.serverTime === "string" ? parseISO8601(reply.serverTime) : null };
}

function schedule(delay: number, work: () => void): void {
  const timer: unknown = setTimeout(work, Math.max(delay, 0));
  // Node: a pending retry must not keep the process alive.
  (timer as { unref?: () => void }).unref?.();
}

const warned = new Set<string>();

function warnOnce(name: string, message: string): void {
  if (warned.has(name)) return;
  warned.add(name);
  log("warning", message);
}

const inflight = new Set<Promise<void>>();

function track(work: Promise<void>): void {
  const tracked: Promise<void> = work.then(
    () => void inflight.delete(tracked),
    () => void inflight.delete(tracked),
  );
  inflight.add(tracked);
}

type Outcome = { kind: "settled" } | { kind: "network" } | { kind: "backoff"; retryAfter: number | null };

const running = new Set<string>();
const waiting = new Set<string>();
const wanted = new Set<string>();
const attempts = new Map<string, number>();

async function modelLoaded(): Promise<void> {
  const who = identity();
  wanted.add(who.namespace);
  await work(who);
}

async function work(who: Identity): Promise<void> {
  const slot = who.namespace;
  // A server with a device id secret licenses the devices it serves, and not itself.
  if (who.platform === "server" && configuredDeviceIdSecret() !== null) {
    wanted.delete(slot);
    return;
  }
  if (running.has(slot) || waiting.has(slot) || !wanted.has(slot)) return;
  running.add(slot);
  let outcome: Outcome;
  try {
    outcome = await advance(who);
  } finally {
    running.delete(slot);
  }
  if (outcome.kind === "settled") {
    wanted.delete(slot);
    return;
  }
  let delay = NETWORK_RETRY_MS;
  if (outcome.kind === "backoff") {
    const attempt = attempts.get(slot) ?? 0;
    attempts.set(slot, attempt + 1);
    delay = licenseBackoff(attempt, outcome.retryAfter);
  }
  waiting.add(slot);
  schedule(delay, () => track(retry(slot)));
}

async function retry(slot: string): Promise<void> {
  waiting.delete(slot);
  const who = identity();
  if (who.namespace !== slot && wanted.delete(slot)) {
    wanted.add(who.namespace);
    attempts.delete(slot);
  }
  await work(who);
}

async function advance(who: Identity): Promise<Outcome> {
  if (isRefused(decodeRecord(await readRecord(recordKey(who.namespace))), Date.now())) return { kind: "settled" };
  const stored = await replaceUnlessValid(who, () => {});
  if (stored.valid) return { kind: "settled" };

  // An install id that could not be stored is not sent: the stored one is read at the next try.
  const id = await currentInstallId().catch(() => null);
  if (id === null) return { kind: "network" };
  const response = await post("license", grantRequest(id, who));
  if (!response) return { kind: "network" };
  const received = Date.now();
  const action = licenseResponseAction(response.status, response.body);
  if (action === "terminal") {
    await replaceUnlessValid(who, (license) => refuse(license, received));
    return { kind: "settled" };
  }
  if (action === "retry-network") return { kind: "network" };
  const granted = action === "done" ? grantedToken(response.body) : null;
  if (!granted) return { kind: "backoff", retryAfter: licenseRetryAfter(response.retryAfter) };

  const serverOffset = granted.serverTime === null ? 0 : granted.serverTime - received;
  const token = parseLicenseToken(granted.token);
  const usable = token !== null && (await isValid({ token: granted.token, serverOffset }));
  if (usable) attempts.delete(who.namespace);
  await replaceUnlessValid(who, (license) => {
    if (!usable) {
      refuse(license, received);
      return;
    }
    license.token = granted.token;
    license.licenseId = token.payload.lid;
    license.period = token.payload.period;
    license.activatedModels = [MODEL];
    license.serverOffset = serverOffset;
    if (license.refusedAt) delete license.refusedAt[MODEL];
  });
  return { kind: "settled" };
}

interface Retry {
  after: number;
  server: boolean;
  cause: string;
}

const NO_ANSWER = "no answer: the connection failed or timed out";

export interface DeviceLicenseSettings {
  post(path: string, payload: unknown): Promise<Reply | null>;
  now(): number;
  schedule(delay: number, work: () => void): void;
  jitter(ceiling: number): number;
  identity(): Identity;
  secret(): string | null;
  installId(deviceId: string, app: string, secret: string | null, apiKey: string | null): Promise<string>;
  publicKeys: Record<string, string>;
  log(level: Exclude<LogLevel, "off">, message: string): void;
  capacity: number;
  queueLimit: number;
  batchItems: number;
}

// Asks for the devices that need a license together, or one by one when the API key cannot batch.
export class DeviceLicenseClient {
  private readonly settings: DeviceLicenseSettings;
  // Until when each device needs no license request: its license's expiry, a day after a refusal, or a minute while its request waits.
  private readonly heldUntil = new Map<string, number>();
  private readonly queue: { deviceId: string; since: number }[] = [];
  private readonly queued = new Set<string>();
  private sending = false;
  private idleWaiters: (() => void)[] = [];
  private limits = 0;
  private limitEnds: number | null = null;
  private timerDue: number | null = null;
  private timerGeneration = 0;
  private attempts = 0;
  // A flush sends before `retryAt`, and never before the time the server asked for.
  private retryAt = 0;
  private serverWaitUntil = 0;
  private singleGrantsUntil = 0;
  private loggedBatchRefusal = false;
  private loggedRetryWait = false;
  private loggedQueueFull = false;

  constructor(settings: Partial<DeviceLicenseSettings> = {}) {
    this.settings = {
      post,
      now: () => Date.now(),
      schedule,
      jitter: (ceiling) => Math.floor(Math.random() * (ceiling + 1)),
      identity,
      secret: configuredDeviceIdSecret,
      installId: deviceInstallId,
      publicKeys: licensePublicKeys,
      log,
      capacity: DEVICE_CAPACITY,
      queueLimit: DEVICE_QUEUE_LIMIT,
      batchItems: DEVICE_BATCH_ITEMS,
      ...settings,
    };
  }

  get waiting(): number {
    return this.queue.length;
  }

  get hasTimer(): boolean {
    return this.timerDue !== null;
  }

  get isSending(): boolean {
    return this.sending;
  }

  begin(deviceId: string): boolean {
    const now = this.settings.now();
    const { capacity } = this.settings;
    const held = this.heldUntil.get(deviceId);
    if (held !== undefined && now < held) return false;
    if (held === undefined && this.heldUntil.size >= capacity) {
      for (const [key, until] of this.heldUntil) if (now >= until) this.heldUntil.delete(key);
      // Forgetting a device only sends its request again, and the server answers with the same license.
      if (this.heldUntil.size >= capacity) {
        let forget = Math.floor(capacity / 2) + 1;
        for (const key of this.heldUntil.keys()) {
          if (forget === 0) break;
          this.heldUntil.delete(key);
          forget -= 1;
        }
      }
    }
    this.heldUntil.set(deviceId, now + DEVICE_REQUEST_HOLD_MS);
    return true;
  }

  private hold(deviceId: string, until: number): void {
    if (!this.heldUntil.has(deviceId) && this.heldUntil.size >= this.settings.capacity) return;
    this.heldUntil.set(deviceId, until);
  }

  license(deviceId: string): void {
    if (this.queued.has(deviceId)) return;
    const { queueLimit, batchItems, now } = this.settings;
    // A device left out of a full queue asks again on a later run, when its hold ends.
    if (this.queue.length >= queueLimit) {
      if (!this.loggedQueueFull) {
        this.loggedQueueFull = true;
        this.settings.log(
          "warning",
          `The license queue is full (${queueLimit} devices wait), so new devices are left out and get a license on a later call. The model keeps running. Check that the license server is reachable and answers in time. See ${SERVER_GUIDE}`,
        );
      }
      return;
    }
    this.queued.add(deviceId);
    this.queue.push({ deviceId, since: now() });
    if (this.queue.length >= batchItems) void this.drain(false);
    else this.arm(Math.max(DEVICE_BATCH_WAIT_MS, this.retryAt - now()));
  }

  // Sends what waits now, never before a time the server asked for, and starts nothing after `budget`.
  async flush(budget: number = FLUSH_MS): Promise<boolean> {
    this.limitSends(this.settings.now() + budget);
    try {
      // A send that another caller started must end before this one returns.
      while (this.sending) await new Promise<void>((resolve) => this.idleWaiters.push(resolve));
      await this.drain(true);
      return this.queue.length === 0;
    } finally {
      this.endLimit();
    }
  }

  // From now until `endLimit`, no request starts after `end`. With several limits, the earliest holds.
  limitSends(end: number): void {
    this.limits += 1;
    this.limitEnds = Math.min(this.limitEnds ?? Infinity, end);
  }

  endLimit(): void {
    this.limits -= 1;
    if (this.limits === 0) this.limitEnds = null;
  }

  private get pastLimit(): boolean {
    return this.limitEnds !== null && this.settings.now() >= this.limitEnds;
  }

  // One timer at a time. A sooner one replaces a later one, and the replaced one does nothing when it fires.
  private arm(delay: number): void {
    const { now } = this.settings;
    const due = now() + Math.min(Math.max(delay, 0), MAX_BACKOFF_MS);
    if (this.timerDue !== null && this.timerDue <= due) return;
    this.timerDue = due;
    this.timerGeneration += 1;
    const armed = this.timerGeneration;
    this.settings.schedule(due - now(), () => {
      if (armed !== this.timerGeneration) return;
      this.timerDue = null;
      void this.drain(false);
    });
  }

  private async drain(force: boolean): Promise<void> {
    if (this.sending) return;
    const { now, batchItems } = this.settings;
    const wait = (force ? this.serverWaitUntil : this.retryAt) - now();
    if (wait > 0) {
      this.arm(wait);
      return;
    }
    this.sending = true;
    try {
      while (this.queue.length > 0) {
        if (this.pastLimit) {
          this.arm(DEVICE_BATCH_WAIT_MS);
          return;
        }
        // Less than a batch waits for more devices, until the oldest has waited its time.
        if (!force && this.queue.length < batchItems) {
          const batchWait = this.queue[0]!.since + DEVICE_BATCH_WAIT_MS - now();
          if (batchWait > 0 && batchWait <= DEVICE_BATCH_WAIT_MS) {
            this.arm(batchWait);
            return;
          }
        }
        const batch = this.queue.slice(0, batchItems).map((wanted) => wanted.deviceId);
        let sent: { settled: number; retry: Retry | null };
        try {
          sent = await this.send(batch);
        } catch {
          sent = { settled: 0, retry: { after: NETWORK_RETRY_MS, server: false, cause: NO_ANSWER } };
        }
        for (const wanted of this.queue.splice(0, sent.settled)) this.queued.delete(wanted.deviceId);
        const { retry } = sent;
        if (retry) {
          if (!this.loggedRetryWait) {
            this.loggedRetryWait = true;
            this.settings.log(
              "warning",
              `Device licensing failed (${retry.cause}) and tries again in ${Math.max(Math.floor(retry.after / 1000), 1)} s. The model keeps running. Check that the license server is reachable. See ${SERVER_GUIDE}`,
            );
          }
          // A connection that fails never shortens a wait the server asked for.
          this.retryAt = Math.max(now() + retry.after, this.serverWaitUntil);
          if (retry.server) this.serverWaitUntil = this.retryAt;
          this.arm(this.retryAt - now());
          return;
        }
        this.retryAt = 0;
        this.serverWaitUntil = 0;
        this.loggedRetryWait = false;
      }
    } finally {
      this.sending = false;
      const waiters = this.idleWaiters;
      this.idleWaiters = [];
      for (const resume of waiters) resume();
    }
  }

  private installId(deviceId: string, who: Identity): Promise<string> {
    return this.settings.installId(deviceId, `${who.platform}:${who.appId}`, this.settings.secret(), who.apiKey);
  }

  private backoff(response: Reply): number {
    this.attempts += 1;
    return licenseBackoff(this.attempts - 1, licenseRetryAfter(response.retryAfter), this.settings.jitter);
  }

  // How many of the batch are settled, from its start, and when to send the rest again.
  private async send(batch: string[]): Promise<{ settled: number; retry: Retry | null }> {
    const { now, post: send } = this.settings;
    const who = this.settings.identity();
    if (who.apiKey === null || now() < this.singleGrantsUntil) return this.sendSingleGrants(batch, who);
    const network = { settled: 0, retry: { after: NETWORK_RETRY_MS, server: false, cause: NO_ANSWER } };
    const items = [];
    for (const deviceId of batch) {
      items.push({ installId: await this.installId(deviceId, who), model: MODEL, modelVersion: MODEL_VERSION });
    }
    const response = await send("licenses", {
      sdk: { name: SDK_NAME, version: SDK_VERSION },
      platform: who.platform,
      app: { id: who.appId },
      key: who.apiKey,
      items,
    });
    if (!response) return network;
    const received = now();
    const action = licenseResponseAction(response.status, response.body);
    // The key cannot batch, or the server has no batch endpoint.
    if (action === "terminal" || response.status === 404) {
      this.singleGrantsUntil = received + DEVICE_SINGLE_GRANTS_MS;
      if (!this.loggedBatchRefusal) {
        this.loggedBatchRefusal = true;
        this.settings.log(
          action === "terminal" ? "warning" : "info",
          `The license server did not accept a batch (HTTP ${response.status}), so each device is one request for the next hour. A batch needs an API key of the Server platform. See ${SERVER_GUIDE}`,
        );
      }
      return this.sendSingleGrants(batch, who);
    }
    if (action === "retry-network") return network;
    const reply = action === "done" ? batchResults(response.body) : null;
    if (!reply || reply.tokens.length !== batch.length) {
      const cause = action === "done" ? "an answer the SDK cannot read" : `HTTP ${response.status}`;
      return { settled: 0, retry: { after: this.backoff(response), server: true, cause } };
    }
    this.attempts = 0;
    for (const [index, deviceId] of batch.entries()) {
      this.hold(deviceId, await this.expiry(reply.tokens[index]!, reply.serverTime, received));
    }
    return { settled: batch.length, retry: null };
  }

  private async sendSingleGrants(batch: string[], who: Identity): Promise<{ settled: number; retry: Retry | null }> {
    const { now, post: send } = this.settings;
    for (const [index, deviceId] of batch.entries()) {
      if (this.pastLimit) return { settled: index, retry: null };
      const network = { settled: index, retry: { after: NETWORK_RETRY_MS, server: false, cause: NO_ANSWER } };
      const response = await send("license", grantRequest(await this.installId(deviceId, who), who));
      if (!response) return network;
      const received = now();
      const action = licenseResponseAction(response.status, response.body);
      if (action === "retry-network") return network;
      if (action === "retry") {
        return { settled: index, retry: { after: this.backoff(response), server: true, cause: `HTTP ${response.status}` } };
      }
      let until = received + TERMINAL_WAIT_MS;
      if (action === "done") {
        const granted = grantedToken(response.body);
        until = await this.expiry(granted?.token ?? null, granted?.serverTime ?? null, received);
        this.attempts = 0;
      }
      this.hold(deviceId, until);
    }
    return { settled: batch.length, retry: null };
  }

  // The local time until which the device needs no request: its license's expiry, or a day for an answer without a license that verifies.
  private async expiry(text: string | null, serverTime: number | null, received: number): Promise<number> {
    const token = text === null ? null : parseLicenseToken(text);
    const verified = token !== null && (await verifyLicenseToken(token, this.settings.publicKeys));
    const end = verified ? parseISO8601(token.payload.periodEnd) : null;
    if (end === null) return received + TERMINAL_WAIT_MS;
    const expiry = end - (serverTime === null ? 0 : serverTime - received);
    return expiry > received ? expiry : received + TERMINAL_WAIT_MS;
  }
}

function batchResults(body: string): { tokens: (string | null)[]; serverTime: number | null } | null {
  const reply = decodeJSON(utf8(body));
  if (!reply || !Array.isArray(reply.results)) return null;
  if (reply.serverTime !== undefined && reply.serverTime !== null && typeof reply.serverTime !== "string") return null;
  const tokens: (string | null)[] = [];
  for (const result of reply.results as unknown[]) {
    if (typeof result !== "object" || result === null || Array.isArray(result)) return null;
    const { token } = result as { token?: unknown };
    if (token !== undefined && token !== null && typeof token !== "string") return null;
    tokens.push(typeof token === "string" ? token : null);
  }
  return { tokens, serverTime: typeof reply.serverTime === "string" ? parseISO8601(reply.serverTime) : null };
}

const devices = new DeviceLicenseClient();

// No device request starts after 10 seconds.
async function flushOwn(): Promise<boolean> {
  const ends = Date.now() + FLUSH_MS;
  devices.limitSends(ends);
  // The license work keeps no process alive by itself, and a flush that is awaited must.
  const keepAlive = setInterval(() => {}, 1000);
  try {
    const awaited = new Set<Promise<void>>();
    while (true) {
      for (const pending of [...inflight]) {
        if (awaited.has(pending)) continue;
        await pending;
        awaited.add(pending);
      }
      const sentAll = await devices.flush(Math.max(ends - Date.now(), 0));
      const started = [...inflight].some((pending) => !awaited.has(pending));
      if (!started || Date.now() >= ends) return sentAll;
    }
  } finally {
    clearInterval(keepAlive);
    devices.endLimit();
  }
}

export const flushLicenses = (): Promise<boolean> => flushCores(flushOwn);

export function licenseOnLoad(): void {
  try {
    registerFlush(flushOwn);
    track(modelLoaded());
  } catch {}
}

export function licenseOnRun(deviceId: unknown): void {
  try {
    // A page is one device, which its install license covers.
    if (platform() !== "server") return;
    const id: unknown = typeof deviceId === "function" ? deviceId() : deviceId;
    const hasSecret = configuredDeviceIdSecret() !== null;
    if (typeof id !== "string" || id === "") {
      if (hasSecret) {
        warnOnce(
          "runWithoutDeviceId",
          `This call has no deviceId, so it gets no device license. Pass a deviceId with every call. See ${SERVER_GUIDE}`,
        );
      }
      return;
    }
    if (!devices.begin(id)) return;
    if (!hasSecret) {
      warnOnce(
        "deviceIdWithoutSecret",
        `deviceId is hashed without a secret, so a guessed device id can be matched to its install id. Set deviceIdSecret in DesertAnt.configure. See ${SERVER_GUIDE}`,
      );
    }
    devices.license(id);
  } catch {}
}
