/**
 * The usage turnstile — a TypeScript port of desert-ant-core's `Sources/Usage`.
 *
 * emo's npm package gets this from the Swift core it wraps (native binding or
 * wasm). This package is a direct port with no core underneath, so the state
 * machine is ported here too. Behaviour, storage keys and wire format all match
 * core exactly, so a device counts once however it reached the endpoint. See
 * docs/USAGE.md.
 *
 * No dependencies: `fetch`, `crypto.randomUUID` and `localStorage` are platform
 * built-ins in every runtime this package supports (browsers, Node 18+, Deno,
 * Bun, workers).
 */

/** The shared ingest endpoint. Every SDK reports to the same place. */
const INGEST_ENDPOINT = "https://events.desertant.com/api/v1/ingest";

/** A persistent install re-emits at most once a day. */
const DAY_MS = 24 * 60 * 60 * 1000;

/** A browser tab is ephemeral, so it uses a session-shaped window instead. */
const WEB_SESSION_MS = 30 * 60 * 1000;

/** Debounce before flushing, matching core's `TrackedSession`. */
const FLUSH_AFTER_MS = 3000;
const SEND_TIMEOUT_MS = 5000;

const DEVICE_ID_KEY = "ai.desertant.usage.deviceId";
const stateKey = (appKey: string, deviceId: string) =>
  `ai.desertant.usage.${appKey}.${deviceId}.state`;

const SDK_NAME = "tongue-js";

export interface UsageState {
  /** Epoch ms we last emitted or went inactive (0 = never). Gates the next emit. */
  lastActiveAt: number;
  /** Calls accrued during throttled sessions, awaiting the next emitted load. */
  carryCallCount: number;
}

interface IngestEvent {
  name: string;
  deviceId: string;
  callCount?: number;
  timestamp?: string;
  context?: Record<string, string>;
}

interface IngestBody {
  platform: string;
  key?: string;
  app?: { id: string };
  sdk: { name: string; version: string };
  sentAt: string;
  events: IngestEvent[];
}

/** A minimal string key/value store the turnstile persists into. */
export interface UsageStorage {
  get(key: string): string | null;
  set(key: string, value: string): void;
}

class MemoryStorage implements UsageStorage {
  private values = new Map<string, string>();
  get(key: string) {
    return this.values.get(key) ?? null;
  }
  set(key: string, value: string) {
    this.values.set(key, value);
  }
}

/**
 * `globalThis.__dalUsageStore` (a host-injected Web-Storage-shaped object, which
 * is how a Node server persists), else `localStorage`, else memory. Same order
 * core uses on WASI.
 */
function defaultStorage(): UsageStorage {
  if (installedStorage) return installedStorage;
  const candidate =
    (globalThis as Record<string, unknown>).__dalUsageStore ??
    (globalThis as Record<string, unknown>).localStorage;
  const store = candidate as
    | { getItem(k: string): string | null; setItem(k: string, v: string): void }
    | undefined;
  if (store && typeof store.getItem === "function" && typeof store.setItem === "function") {
    return {
      get: (key) => {
        try {
          return store.getItem(key);
        } catch {
          return null; // Safari private mode throws on access
        }
      },
      set: (key, value) => {
        try {
          store.setItem(key, value);
        } catch {
          /* quota or private mode; reporting is best-effort */
        }
      },
    };
  }
  return new MemoryStorage();
}

/**
 * A host-installed synchronous store, set by `Tongue.load()` on Node.
 *
 * Node has no `localStorage`, so without this every process minted a fresh device
 * id — and billing counts distinct devices, so a server-side customer was billed
 * per process start. `load()` is already async and already imports node builtins,
 * so it installs a file-backed store here before the model is constructed. Doing
 * it there rather than with a dynamic require keeps this module free of any
 * Node-only import, which is what lets the same file run in a browser.
 */
let installedStorage: UsageStorage | undefined;

/** Install the process-wide store. Called by `Tongue.load()` on Node. */
export function setUsageStorage(storage: UsageStorage): void {
  installedStorage = storage;
}

function uuid(): string {
  const c = (globalThis as { crypto?: Crypto }).crypto;
  if (c && typeof c.randomUUID === "function") return c.randomUUID();
  // RFC 4122 v4 from getRandomValues, or Math.random where neither exists.
  const bytes = new Uint8Array(16);
  if (c && typeof c.getRandomValues === "function") c.getRandomValues(bytes);
  else for (let i = 0; i < 16; i++) bytes[i] = Math.floor(Math.random() * 256);
  bytes[6] = (bytes[6]! & 0x0f) | 0x40;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const hex = [...bytes].map((b) => b.toString(16).padStart(2, "0"));
  return `${hex.slice(0, 4).join("")}-${hex.slice(4, 6).join("")}-${hex
    .slice(6, 8)
    .join("")}-${hex.slice(8, 10).join("")}-${hex.slice(10).join("")}`;
}

/** True in a browser-origin runtime: a page, or a worker a page spawned. */
function isBrowserOrigin(): boolean {
  const g = globalThis as {
    document?: unknown;
    importScripts?: unknown;
    WorkerGlobalScope?: abstract new () => object;
  };
  if (typeof g.document !== "undefined") return true;
  // A worker in a server runtime (Deno, Bun, Node) has WorkerGlobalScope too, but
  // no Origin: tagged `web` without one it has no identity and gets a 400.
  const server = globalThis as { Deno?: unknown; process?: { versions?: { node?: string; bun?: string } } };
  if (typeof server.Deno !== "undefined" || server.process?.versions?.node || server.process?.versions?.bun) {
    return false;
  }
  if (typeof g.importScripts === "function") return true;
  const scope = g.WorkerGlobalScope;
  return typeof scope === "function" && globalThis instanceof scope;
}

/**
 * What one reading of the runtime implies for attribution: the platform tag and
 * the window. Derived once per client so the tag, the window and the key's
 * placement cannot disagree, and so a global appearing or disappearing mid-run
 * cannot change the answer. The endpoint accepts exactly ios|android|web|server
 * and rejects anything else with a 400, which drops the event silently: Node is
 * a `server`, not a `node`.
 */
function attribution(browserOrigin: boolean): { platform: string; windowMs: number } {
  return browserOrigin
    ? { platform: "web", windowMs: WEB_SESSION_MS }
    : { platform: "server", windowMs: DAY_MS };
}

/** The platform tag this process reports. */
export function defaultPlatform(): string {
  return attribution(isBrowserOrigin()).platform;
}

/** The ingest endpoint. A host may override it for tests and local capture. */
function ingestEndpoint(): string {
  return hostString("__dalIngestEndpoint", "DAL_INGEST_ENDPOINT") ?? INGEST_ENDPOINT;
}

/**
 * Whether the key can ride an `Authorization` header on every send path here.
 *
 * A browser-origin runtime cannot: its unload flush goes through `sendBeacon`,
 * which takes no headers, and a beacon without the key arrives unattributed. So
 * it is the one runtime that keeps the key in the body. Read once per client, by
 * `create`, which hands the answer to `makeSend`.
 */
function keyRidesInHeader(browserOrigin: boolean): boolean {
  return !browserOrigin;
}

/**
 * A host override, read from a JS global or the matching environment variable.
 *
 * The env name is passed in rather than derived. Deriving it with
 * `name.replace(/^__dal/,"DAL_").toUpperCase()` turned `__dalApiKey` into
 * `DAL_APIKEY`, so a Node customer who set `DAL_API_KEY` — the name core and the
 * Kotlin port document — got bodies with no `key` at all and no way to notice.
 */
function hostString(name: string, envName: string): string | undefined {
  // Trimmed: a value read from a secret file often ends in a newline, which an
  // `Authorization` header rejects and the POST is lost with it.
  const value = (globalThis as Record<string, unknown>)[name];
  if (typeof value === "string" && value.trim()) return value.trim();
  if (typeof value === "function") {
    const resolved = (value as () => unknown)();
    if (typeof resolved === "string" && resolved.trim()) return resolved.trim();
  }
  const env = (globalThis as { process?: { env?: Record<string, string> } }).process?.env;
  return env?.[envName]?.trim() || undefined;
}

/** Whether usage reporting is switched off for this process. See docs/USAGE.md. */
export function usageDisabled(): boolean {
  const env = (globalThis as { process?: { env?: Record<string, string> } }).process?.env;
  const value =
    env?.DAL_USAGE_DISABLED ??
    ((globalThis as Record<string, unknown>).__dalUsageDisabled as string | undefined);
  return Boolean(value) && value !== "0";
}

/**
 * Attribution. A browser is identified by its Origin server-side, so it sends no
 * `app`; off-browser there is no Origin, so the host name stands in — matching
 * core, which sends the bundle id or package name.
 */
function defaultAppId(): string | undefined {
  if (isBrowserOrigin()) return undefined;
  return (
    hostString("__dalAppId", "DAL_APP_ID") ??
    (globalThis as { process?: { title?: string } }).process?.title ??
    "unknown"
  );
}

/** Serialize exactly as core does: declaration order, nulls omitted. */
function buildBody(body: IngestBody): string {
  return JSON.stringify(body);
}

/**
 * The client state machine. A direct port of core's `UsageClient`; the comments
 * there explain why each branch exists.
 */
export class UsageClient {
  private sessionCalls = 0;
  private pending: IngestEvent | null = null;
  private emitted = false;

  constructor(
    private deps: {
      deviceId: string;
      key?: string;
      /** False where the transport sends the key as an `Authorization` header. */
      keyInBody: boolean;
      appId?: string;
      platform: string;
      version: string;
      windowMs: number;
      now: () => number;
      loadState: () => UsageState;
      saveState: (state: UsageState) => void;
      send: (body: IngestBody) => Promise<void> | void;
    },
  ) {}

  recordCall(n = 1): void {
    if (n > 0) this.sessionCalls += n;
  }

  /** Whether there is usage to report, so a forced flush never invents a call. */
  get hasUsage(): boolean {
    return this.sessionCalls > 0 || this.deps.loadState().carryCallCount > 0;
  }

  /**
   * Force a turnstile now, ignoring the window, and hand back the send's
   * completion so a caller can await the POST. Port of core's `load()`.
   */
  load(): Promise<void> | void {
    const st = this.deps.loadState();
    this.deps.saveState({ lastActiveAt: this.deps.now(), carryCallCount: st.carryCallCount });
    this.queue();
    return this.flush();
  }

  start(): void {
    const st = this.deps.loadState();
    if (this.deps.now() - st.lastActiveAt < this.deps.windowMs) return;
    this.deps.saveState({ lastActiveAt: this.deps.now(), carryCallCount: st.carryCallCount });
    this.queue();
  }

  suspend(): void {
    const st = this.deps.loadState();
    this.deps.saveState({ lastActiveAt: this.deps.now(), carryCallCount: st.carryCallCount });
    this.flush();
  }

  flush(): Promise<void> | void {
    const st = this.deps.loadState();

    if (this.pending) {
      const event = this.pending;
      this.pending = null;
      const count = this.resolveCount(st.carryCallCount + this.sessionCalls);
      if (count !== undefined) event.callCount = count;
      this.deps.saveState({ lastActiveAt: st.lastActiveAt, carryCallCount: 0 });
      this.sessionCalls = 0;
      return this.deps.send(this.makeBody([event]));
    }

    if (this.emitted && this.sessionCalls > 0) {
      const count = this.resolveCount(this.sessionCalls);
      const event: IngestEvent = { name: "load", deviceId: this.deps.deviceId };
      if (count !== undefined) event.callCount = count;
      this.sessionCalls = 0;
      return this.deps.send(this.makeBody([event]));
    }

    if (!this.emitted && this.sessionCalls > 0) {
      this.deps.saveState({
        lastActiveAt: st.lastActiveAt,
        carryCallCount: st.carryCallCount + this.sessionCalls,
      });
      this.sessionCalls = 0;
    }
  }

  private resolveCount(accumulated: number): number | undefined {
    return accumulated > 0 ? accumulated : undefined;
  }

  private queue(): void {
    this.pending = { name: "load", deviceId: this.deps.deviceId };
    this.emitted = true;
  }

  private makeBody(events: IngestEvent[]): IngestBody {
    // Built in one literal, in core's declaration order. Assigning `key` and
    // `app` afterwards put them last, because JSON.stringify follows insertion
    // order — so the two ports posted the same data under different byte
    // sequences while Wire.kt claimed they were identical.
    return {
      platform: this.deps.platform,
      ...(this.deps.keyInBody && this.deps.key ? { key: this.deps.key } : {}),
      ...(this.deps.appId ? { app: { id: this.deps.appId } } : {}),
      sdk: { name: SDK_NAME, version: this.deps.version },
      sentAt: new Date(this.deps.now()).toISOString(),
      events,
    };
  }
}

/**
 * Exported so a test can drive the real transport at a local endpoint. The
 * default endpoint is overridable only through `__dalIngestEndpoint` /
 * `DAL_INGEST_ENDPOINT`, the same host override core offers, and `UsageTurnstile`
 * always goes through it. Without this the HTTP path was never executed by any
 * test: the state machine was covered, the send was not.
 *
 * A key rides an `Authorization` header rather than the body: every runtime this
 * package supports sets request headers, and the endpoint prefers the header. A
 * browser-origin runtime keeps it in the body, because its unload flush goes
 * through `sendBeacon`, which cannot carry a header.
 *
 * `keyInHeader` is a parameter, not a re-reading of the runtime, so the
 * placement cannot differ between the body and the header on one request.
 *
 * Returns the send's promise so `flushTelemetry()` can await the POST. The
 * debounced path ignores it, exactly as core's fire-and-forget send does.
 */
export function makeSend(
  endpoint = INGEST_ENDPOINT,
  bearerKey?: string,
  keyInHeader: boolean = keyRidesInHeader(isBrowserOrigin()),
): (body: IngestBody) => Promise<void> {
  return (body) => {
    let json: string;
    try {
      json = buildBody(body);
    } catch {
      return Promise.resolve();
    }
    try {
      const beacon = (globalThis as { navigator?: { sendBeacon?: (u: string, d: string) => boolean } })
        .navigator?.sendBeacon;
      const headers: Record<string, string> = { "Content-Type": "application/json" };
      if (bearerKey && keyInHeader) headers.Authorization = `Bearer ${bearerKey}`;
      // Bounded as the Kotlin port's connection is, so an endpoint that accepts
      // and never answers cannot hold `flushTelemetry()`, and with it a
      // process's exit, for undici's five minute default.
      const signal =
        typeof AbortSignal !== "undefined" && typeof AbortSignal.timeout === "function"
          ? AbortSignal.timeout(SEND_TIMEOUT_MS)
          : undefined;
      return fetch(endpoint, {
        method: "POST",
        headers,
        body: json,
        keepalive: true,
        signal,
      }).then(
        () => undefined,
        (error: unknown) => {
          // Best effort. A blocked request must never surface to the caller.
          // A timed-out one may already have landed, so it is not sent again.
          if ((error as { name?: string } | null)?.name === "TimeoutError") return;
          if (beacon) try { beacon.call(globalThis.navigator, endpoint, json); } catch { /* ignore */ }
        },
      );
    } catch {
      /* no fetch in this runtime; reporting is best-effort */
      return Promise.resolve();
    }
  };
}

/**
 * Owns the turnstile for one `Tongue`. The equivalent of core's `TrackedSession`,
 * which this package cannot use — there is no inference session here.
 */
export class UsageTurnstile {
  private flushTimer: ReturnType<typeof setTimeout> | null = null;
  /**
   * Every send this turnstile started that has not finished: the debounce's, the
   * exit hook's and earlier forced flushes'. `flushTelemetry()` awaits them all:
   * the one it starts itself may be nothing, because the POST carrying its calls
   * is already in flight. Every one, not the newest: fetches run concurrently, so
   * on a slow endpoint an older POST can outlive a newer one.
   */
  private inflight = new Set<Promise<void>>();

  /** Keep `sent` in `inflight` until it settles. */
  private track(sent: Promise<void> | void): void {
    if (!sent) return;
    const pending: Promise<void> = Promise.resolve(sent)
      .catch(() => undefined)
      .then(() => {
        this.inflight.delete(pending);
      });
    this.inflight.add(pending);
  }

  private constructor(private client: UsageClient) {}

  /**
   * Returns null when usage is switched off. Never throws: a blocked store or an
   * unusual runtime means no reporting, not no detection.
   */
  static create(version: string, storage?: UsageStorage): UsageTurnstile | null {
    if (usageDisabled()) return null;
    try {
      const store = storage ?? defaultStorage();
      // A host-provided id wins, matching core's resolveDeviceId: a server that
      // knows its own device identity sets globalThis.__dalDeviceId.
      let device = hostString("__dalDeviceId", "DAL_DEVICE_ID") ?? store.get(DEVICE_ID_KEY);
      if (!device) {
        device = uuid();
        store.set(DEVICE_ID_KEY, device);
      }
      const appId = defaultAppId();
      const key = hostString("__dalApiKey", "DAL_API_KEY");
      const namespace = key ?? appId ?? "unknown";
      // One reading of the runtime, feeding the platform tag, the window, the
      // key's placement, the transport's header decision and the unload hook.
      const browserOrigin = isBrowserOrigin();
      const { platform, windowMs } = attribution(browserOrigin);
      const keyInHeader = keyRidesInHeader(browserOrigin);
      const client = new UsageClient({
        deviceId: device,
        key,
        keyInBody: !keyInHeader,
        appId,
        platform,
        version,
        windowMs,
        now: () => Date.now(),
        loadState: () => {
          const raw = store.get(stateKey(namespace, device!));
          if (!raw) return { lastActiveAt: 0, carryCallCount: 0 };
          const [last, carry] = raw.split(",");
          const lastActiveAt = Number(last);
          const carryCallCount = Number(carry);
          if (!Number.isFinite(lastActiveAt) || !Number.isFinite(carryCallCount)) {
            return { lastActiveAt: 0, carryCallCount: 0 };
          }
          return { lastActiveAt, carryCallCount };
        },
        saveState: (state) =>
          store.set(stateKey(namespace, device!), `${state.lastActiveAt},${state.carryCallCount}`),
        send: makeSend(ingestEndpoint(), key, keyInHeader),
      });
      client.start();
      const turnstile = new UsageTurnstile(client);
      // Deliver what was accrued when the host goes away. Without this a process
      // or tab that ends inside the 3 s debounce sends nothing at all, while
      // `start()` has already stamped the window — so a short-lived Node script
      // would report zero every day, permanently.
      if (browserOrigin && typeof addEventListener === "function") {
        addEventListener("pagehide", () => turnstile.client.suspend());
      } else {
        const proc = (globalThis as { process?: { once?: (e: string, f: () => void) => void } }).process;
        // `beforeExit` still allows work to be scheduled, unlike `exit`.
        proc?.once?.("beforeExit", () => {
          try {
            turnstile.track(turnstile.client.flush());
          } catch {
            /* best effort */
          }
        });
      }
      return turnstile;
    } catch {
      return null;
    }
  }

  /** One detection. */
  record(): void {
    this.client.recordCall();
    if (this.flushTimer !== null) return;
    this.flushTimer = setTimeout(() => {
      this.flushTimer = null;
      try {
        this.track(this.client.flush());
      } catch {
        /* best effort */
      }
    }, FLUSH_AFTER_MS);
    // Never hold a Node process open for a pending flush.
    (this.flushTimer as { unref?: () => void }).unref?.();
  }

  /**
   * Send what this turnstile has recorded and await the POST, so a process that
   * ends right after a detection does not exit before it lands. One load per
   * device per call, whatever the re-emit window says: the forced emit core's
   * `flushTelemetry()` performs. A turnstile with nothing recorded sends
   * nothing and reports true: an idle process must not invent a billable load.
   */
  async flushTelemetry(): Promise<boolean> {
    this.cancelFlush();
    try {
      if (this.client.hasUsage) this.track(this.client.load());
      await Promise.all([...this.inflight]);
      return true;
    } catch {
      return false;
    }
  }

  /** Drop the pending debounce, so a forced flush is not followed by a second send. */
  private cancelFlush(): void {
    if (this.flushTimer === null) return;
    clearTimeout(this.flushTimer);
    this.flushTimer = null;
  }
}
