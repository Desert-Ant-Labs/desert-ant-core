// Shared through globalThis, so two copies of this package in one app still configure every loaded core.
const STATE = Symbol.for("desert-ant-labs.configure");
const state = (globalThis[STATE] ??= { settings: { apiKey: null, deviceIdSecret: null }, cores: new Set() });

// Only Node counts devices for a server. A page, a browser worker and an edge runtime are not one.
const onAServer = () =>
  typeof globalThis.process?.versions?.node === "string" && !(typeof window !== "undefined" && typeof window.document !== "undefined");

export function configure({ apiKey, deviceIdSecret } = {}) {
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

export function registerCore(apply) {
  if (state.settings.apiKey !== null) apply(state.settings);
  state.cores.add(apply);
}

// An older copy of this package makes the shared state without `flushes`, and its cores have no entry in it.
const flushes = () => (state.flushes ??= new Set());

export function registerFlush(flush) {
  flushes().add(flush);
}

// Each core has its own license queue, so one flush runs them all. Resolves true when every core sent everything.
export async function flushCores(own) {
  const all = new Set(flushes());
  if (own) all.add(own);
  const settled = await Promise.allSettled([...all].map(async (flush) => flush()));
  const failed = settled.find((one) => one.status === "rejected");
  if (failed) throw failed.reason;
  return settled.every((one) => one.value !== false);
}
