export interface DesertAntSettings {
  /** The API key from platform.desertant.com. */
  apiKey: string;
  /** Only for a server: 32 or more random bytes as text, kept on the server and never changed. */
  deviceIdSecret?: string;
}

interface Settings {
  apiKey: string | null;
  deviceIdSecret: string | null;
}

type Flush = () => Promise<boolean>;

interface SharedState {
  settings: Settings;
  cores: Set<(settings: Settings) => void>;
  flushes?: Set<Flush>;
}

// The same slot @desert-ant-labs/core uses, so a configure from any Desert Ant package reaches this one.
const STATE = Symbol.for("desert-ant-labs.configure");
const host = globalThis as unknown as Record<symbol, SharedState | undefined>;
const state = (host[STATE] ??= { settings: { apiKey: null, deviceIdSecret: null }, cores: new Set() });

interface NodeProcess {
  versions?: { node?: unknown };
  env?: Record<string, string | undefined>;
  title?: unknown;
}

export const nodeProcess = (): NodeProcess | undefined => (globalThis as { process?: NodeProcess }).process;

export const isNode = (): boolean => typeof nodeProcess()?.versions?.node === "string";

const onAServer = (): boolean =>
  isNode() && !(typeof window !== "undefined" && typeof window.document !== "undefined");

function configure({ apiKey, deviceIdSecret }: DesertAntSettings = {} as DesertAntSettings): void {
  if (typeof apiKey !== "string") throw new TypeError("DesertAnt.configure: apiKey must be a string");
  if (deviceIdSecret !== undefined) {
    if (typeof deviceIdSecret !== "string" || deviceIdSecret.trim() === "") {
      throw new TypeError("DesertAnt.configure: deviceIdSecret must be a non-empty string");
    }
    if (!onAServer()) {
      throw new TypeError("DesertAnt.configure: deviceIdSecret is for servers. A secret in a page or a worker is public.");
    }
  }
  state.settings = { apiKey, deviceIdSecret: deviceIdSecret ?? state.settings.deviceIdSecret ?? null };
  for (const apply of state.cores) apply(state.settings);
}

export type LogLevel = "debug" | "info" | "warning" | "error" | "off";

const LOG_LEVELS: readonly LogLevel[] = ["debug", "info", "warning", "error", "off"];
const LOG_ALIASES: Record<string, LogLevel> = { verbose: "debug", warn: "warning", silent: "off", none: "off" };
const LOG_INSTALLERS = Symbol.for("desert-ant-labs.log-installers");

// The level and the logger live in the two globals @desert-ant-labs/core uses, so one setting covers every model.
const logHost = globalThis as unknown as { __dalLogLevel?: unknown; __dalLog?: unknown } & Record<symbol, Set<() => void> | undefined>;

function hostLogLevel(): LogLevel {
  const raw = logHost.__dalLogLevel;
  if (typeof raw !== "string") return "warning";
  const name = raw.trim().toLowerCase();
  const level = LOG_ALIASES[name] ?? (name as LogLevel);
  return LOG_LEVELS.includes(level) ? level : "warning";
}

type Logger = (level: LogLevel, source: string, message: string) => void;

const hostLogger = (): Logger | null => (typeof logHost.__dalLog === "function" ? (logHost.__dalLog as Logger) : null);

function reinstall(): void {
  for (const install of logHost[LOG_INSTALLERS] ?? []) install();
}

export function log(level: Exclude<LogLevel, "off">, message: string): void {
  try {
    const least = hostLogLevel();
    if (least === "off" || LOG_LEVELS.indexOf(level) < LOG_LEVELS.indexOf(least)) return;
    const logger = hostLogger();
    if (logger) logger(level, "core", message);
    else console[level === "warning" ? "warn" : level](`[desert-ant] core: ${message}`);
  } catch {}
}

export const DesertAnt: {
  /** Sets the API key before the first model loads, and on a server the device id secret. Each call replaces the earlier key. */
  configure(settings: DesertAntSettings): void;
  /** The least severe level the SDK writes. `"warning"` by default. Set it at any time. */
  logLevel: LogLevel;
  /** Receives every SDK message instead of the console, as `(level, source, message)`. Null (the default) is the console. */
  logger: Logger | null;
} = {
  configure,
  get logLevel() {
    return hostLogLevel();
  },
  set logLevel(level) {
    if (typeof level !== "string" || !LOG_LEVELS.includes(level.trim().toLowerCase() as LogLevel)) {
      throw new Error(`DesertAnt.logLevel: expected one of ${LOG_LEVELS.join(", ")}, got ${String(level)}`);
    }
    logHost.__dalLogLevel = level.trim().toLowerCase();
    reinstall();
  },
  get logger() {
    return hostLogger();
  },
  set logger(handler) {
    if (handler !== null && typeof handler !== "function") {
      throw new Error("DesertAnt.logger: expected a function or null");
    }
    logHost.__dalLog = handler ?? undefined;
    reinstall();
  },
};

const trimmed = (value: unknown): string | null => {
  if (typeof value !== "string") return null;
  const text = value.trim();
  return text === "" ? null : text;
};

export const configuredApiKey = (): string | null => trimmed(state.settings?.apiKey);

export const configuredDeviceIdSecret = (): string | null => trimmed(state.settings?.deviceIdSecret);

export function registerFlush(flush: Flush): void {
  (state.flushes ??= new Set()).add(flush);
}

export async function flushCores(own: Flush): Promise<boolean> {
  const all = new Set(state.flushes ?? []);
  all.add(own);
  const settled = await Promise.allSettled([...all].map(async (flush) => flush()));
  const failed = settled.find((one) => one.status === "rejected");
  if (failed) throw failed.reason;
  return settled.every((one) => one.status === "fulfilled" && one.value !== false);
}
