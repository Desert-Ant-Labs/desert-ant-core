// On-device __DESCRIPTION_SHORT__ for JavaScript. The universal entry: it resolves
// model assets, owns the LiteRT.js session (via @desert-ant-labs/core), and
// exposes the public API. Runs in the browser and, via the `#platform` seam,
// server-side in Node. For the prebuilt native server core, import
// `@desert-ant-labs/__MODEL__/native`.
import { setupCore, defaultWasmDir, readModelSource, defaultCacheRoot } from "#platform";
import { installLiteRtHost, loadLiteRt, assertBrowserRuntime } from "@desert-ant-labs/core";

const PACKAGE_NAME = "@desert-ant-labs/__MODEL__";

const core = await setupCore();

/** On-device __DESCRIPTION_SHORT__. Create one with `await __PRODUCT__.load(...)`. */
export class __PRODUCT__ {
  static async load(options = {}) {
    assertBrowserRuntime({ packageName: PACKAGE_NAME, litert: options.litert });
    const lrt = await loadLiteRt({
      litert: options.litert,
      wasmDir: options.litertWasmDir,
      defaultWasmDir,
      packageName: PACKAGE_NAME,
    });
    const { loadAndCompile, Tensor } = lrt;
    const accelerator = options.accelerator ?? "wasm";

    const { setModel } = installLiteRtHost({
      hostGlobal: "__HOSTGLOBAL__",
      accelerator,
      loadAndCompile,
      Tensor,
      readModelSource,
    });

    const onProgress = typeof options.onProgress === "function" ? options.onProgress : undefined;
    if (options.modelBaseUrl != null) {
      const { metaJSON, modelBytes } = await fetchModelFrom(options.modelBaseUrl);
      setModel(await loadAndCompile(modelBytes, { accelerator }));
      await core.loadBundled(metaJSON);
      onProgress?.(1);
    } else {
      const cacheRoot = await defaultCacheRoot();
      await core.load(cacheRoot, options.directory ?? "", onProgress);
    }
    return new __PRODUCT__();
  }

  async run(input, options = {}) {
    return core.run(String(input ?? ""), options.minimumConfidence ?? 0);
  }

  /** No-op in the WebAssembly runtime; present so the same code works against
   *  the native server build (`@desert-ant-labs/__MODEL__/native`). */
  dispose() {}
}

// Self-hosted model files (the `modelBaseUrl` opt-out).
async function fetchModelFrom(baseUrl) {
  const base = baseUrl.endsWith("/") ? baseUrl : `${baseUrl}/`;
  const [meta, model] = await Promise.all([
    fetch(`${base}__MODEL___meta.json`).then((r) => r.text()),
    fetch(`${base}__MODEL__.tflite`).then((r) => r.arrayBuffer()),
  ]);
  return { metaJSON: meta, modelBytes: new Uint8Array(model) };
}
