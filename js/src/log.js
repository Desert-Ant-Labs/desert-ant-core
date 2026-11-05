// The SDK's log, from JavaScript: `DesertAnt.logLevel` and `DesertAnt.logger`,
// the same names as the Kotlin SDK's, which every model package re-exports.
// Every message the Swift core and the runtime it drives write goes through the
// core's `Log` (Sources/PlatformSupport/Log.swift); this is the host's side of
// it, the same on both runtimes.
//
// The two settings are kept in `globalThis.__dalLogLevel` and `__dalLog`, which
// is how they reach a wasm core (its Swift reads them, like the other `__dal*`
// host settings) and how one setting covers every core in the process. The
// globals are the transport, not the API. A core already loaded registers an
// installer, so a later change reaches it too.
//
// Browser-safe: no `node:*`.

export const LOG_LEVELS = ["debug", "info", "warning", "error", "off"];

const INSTALLERS = Symbol.for("desert-ant-labs.log-installers");

/** The level name a host wrote, normalized to {@link LOG_LEVELS}; null for none. */
export function hostLogLevel() {
  const raw = globalThis.__dalLogLevel;
  if (typeof raw !== "string") return null;
  const name = raw.trim().toLowerCase();
  const alias = { verbose: "debug", warn: "warning", silent: "off", none: "off" }[name] ?? name;
  return LOG_LEVELS.includes(alias) ? alias : null;
}

/** The handler a host set, when it is a function. */
export function hostLogHandler() {
  const handler = globalThis.__dalLog;
  return typeof handler === "function" ? handler : null;
}

/** A native core registers how to apply the globals, so a later change reaches it. */
export function registerLogInstaller(install) {
  (globalThis[INSTALLERS] ??= new Set()).add(install);
}

function reinstall() {
  for (const install of globalThis[INSTALLERS] ?? []) install();
}

/**
 * The SDK's settings, for every Desert Ant model in the process, on either
 * runtime. `logLevel` is the least severe level that is written: `"debug"`,
 * `"info"`, `"warning"` (the default), `"error"` or `"off"`. `logger` receives
 * every message instead of the platform's log (the unified log on macOS,
 * standard error on Linux and Windows, the console on wasm):
 * `(level, source, message)`, where `level` is a {@link LOG_LEVELS} name and
 * `source` is what wrote it (`core`, `http`, `litert`, a model id). Null (the
 * default) is the platform's log.
 */
export const DesertAnt = {
  get logLevel() {
    return hostLogLevel() ?? "warning";
  },
  set logLevel(level) {
    if (typeof level !== "string" || !LOG_LEVELS.includes(level.trim().toLowerCase())) {
      throw new Error(`DesertAnt.logLevel: expected one of ${LOG_LEVELS.join(", ")}, got ${String(level)}`);
    }
    globalThis.__dalLogLevel = level.trim().toLowerCase();
    reinstall();
  },
  get logger() {
    return hostLogHandler();
  },
  set logger(handler) {
    if (handler !== null && typeof handler !== "function") {
      throw new Error("DesertAnt.logger: expected a function or null");
    }
    globalThis.__dalLog = handler ?? undefined;
    reinstall();
  },
};
