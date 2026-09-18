// Node half of the platform seam for the universal entry (browser.js) when it
// runs server-side: the Client-Component SSR pass a framework renders in Node,
// and a server that transcribes with a Node runtime. Bundlers resolve this file
// only through the non-browser ("default") condition of `#platform`, so the
// browser bundle never sees `node:*`.
//
// Voz has no native core: unlike Clear or Emo there is no `dal_*` C ABI for it
// (see the Voz comment in Package.swift), so Node runs the same WebAssembly
// core the browser does. What differs is the runtime underneath it - a Node
// caller passes `onnxruntime-node`, which exposes the same InferenceSession and
// Tensor API - and where the bundle is cached.
import { installAudioHost } from "@desert-ant-labs/core/audio/node";

export async function setupCore() {
  const { instantiate } = await import("./dist/instantiate.js");
  const { defaultNodeSetup } = await import("./dist/platforms/node.js");
  const { exports } = await instantiate({
    ...(await defaultNodeSetup({})),
    getImports: () => imports,
  });
  return { exports };
}

/** See the note in platform-browser.js: Voz never calls this seam, but the
 *  generated instantiator asks for it. */
const imports = {
  dalModelHost: {
    createSessionFromPath: unreachable,
    createSessionFromBytes: unreachable,
    run: unreachable,
  },
};

async function unreachable() {
  throw new Error("voz: the shared model host is not part of this model's path");
}

export async function defaultOrtWasmDir() {
  return undefined;
}

/**
 * Under Node the runtime stays the caller's, unlike in the browser.
 *
 * It is a different package there - onnxruntime-node, a native addon with the
 * same InferenceSession and Tensor API - and importing it from this file would
 * put that addon in the SSR graph. That is what `js/test/ssr-graph.test.mjs`
 * exists to prevent for koffi, and it is a real failure rather than a strict
 * check: esbuild cannot bundle the `.node` binaries at all.
 *
 * So this throws the instruction instead of guessing.
 */
export async function defaultRuntime(packageName) {
  throw new Error(
    `${packageName} needs a runtime under Node: npm i onnxruntime-node, then `
      + 'pass it in - import * as ort from "onnxruntime-node"; '
      + "Voz.load({ ort }). It is not imported here because a native addon in "
      + "the module graph breaks a bundled server build.",
  );
}

/**
 * Read bundle files through a disk cache under the platform cache root, the
 * same place the Swift SDKs keep their models:
 * `<cache>/desert-ant-models/<repo>/<revision>/web/<file>`.
 *
 * Written to a temporary name and renamed, so an interrupted download is not
 * left behind as a short file that later reads as valid.
 */
export async function makeFetchFile({ info, revision, cache, onProgress }) {
  const [{ default: fs }, { default: path }, { default: os }] = await Promise.all([
    import("node:fs"), import("node:path"), import("node:os"),
  ]);
  const root = process.env.DAL_CACHE_ROOT
    ?? (process.platform === "darwin"
      ? path.join(os.homedir(), "Library", "Caches")
      : process.env.XDG_CACHE_HOME ?? path.join(os.homedir(), ".cache"));
  const dir = path.join(root, "desert-ant-models", ...info.repo.split("/"), revision, "web");
  let done = 0;
  const names = new Set();

  return async (url, name) => {
    names.add(name);
    const file = path.join(dir, path.basename(name));
    if (cache && fs.existsSync(file)) {
      const bytes = new Uint8Array(fs.readFileSync(file));
      onProgress?.(++done / Math.max(names.size, 1));
      return bytes;
    }
    const response = await fetch(url);
    if (!response.ok) throw new Error(`voz: ${name} -> HTTP ${response.status}`);
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (cache) {
      fs.mkdirSync(dir, { recursive: true });
      const temporary = `${file}.${process.pid}.partial`;
      fs.writeFileSync(temporary, bytes);
      fs.renameSync(temporary, file);
    }
    onProgress?.(++done / Math.max(names.size, 1));
    return bytes;
  };
}

/**
 * Node has no WebGPU, so the graphs run on the CPU.
 *
 * "cpu" and not "wasm": the provider names are the runtime's, and
 * onnxruntime-node has no wasm backend at all - asking for one fails with "no
 * available backend found" rather than falling back. The browser's runtime is
 * the other way round.
 */
export async function bestProvider() {
  return "cpu";
}

/**
 * A Blob for a path on disk, so a file streams under Node too.
 *
 * `fs.openAsBlob` is the whole point: it hands back a Blob backed by the file
 * rather than its contents, so `slice()` reads from disk and an hour-long
 * recording costs a chunk at a time here as well as in a browser.
 */
export async function asBlob(input) {
  if (typeof Blob !== "undefined" && input instanceof Blob) return input;
  if (typeof input !== "string") return null;
  const fs = await import("node:fs");
  if (!fs.openAsBlob) return null;                     // Node < 20
  return fs.openAsBlob(input).catch(() => null);
}

/** A relative `modelBaseUrl` under Node is a path on disk, so it resolves
 *  against the working directory. A caller serving the bundle over HTTP passes
 *  an absolute URL. */
export function pageUrl() {
  return `file://${process.cwd()}/`;
}

/** Node has no Web Audio, so this is the portable WAV codec: WAV in, mono at
 *  the requested rate out. Anything else has to be decoded by the caller. */
export async function decodeAudio(bytes, sampleRate) {
  return installAudioHost().decode(null, bytes, sampleRate);
}
