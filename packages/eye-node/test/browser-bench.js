// Throughput in the browser (DAL_BROWSER_CASE=browser-bench.js node js/test/browser/run.mjs --only eye):
// the bench.js cases with the default accelerator, then LiteRT.js wasm and WebGPU explicitly.
import { bench } from "./bench.js";

const RESOURCES = "/Tests/EyeTests/Resources/";

export async function run({ Eye }, { litert, litertWasmDir }) {
  const golden = await (await fetch(RESOURCES + "eye_golden.json")).json();
  const gray = new Uint8Array(await (await fetch(RESOURCES + "eye_fixture.gray")).arrayBuffer());
  const { width, height } = golden.fixture;
  const pixels = { data: new Uint8Array(width * height * 3), width, height };
  gray.forEach((v, i) => pixels.data.set([v, v, v], i * 3));
  const out = { userAgent: navigator.userAgent, threads: self.crossOriginIsolated === true };
  for (const accelerator of ["default", "wasm", "webgpu"]) {
    try {
      const t = performance.now();
      const eye = await Eye.load({ litert, litertWasmDir, ...(accelerator === "default" ? {} : { accelerator }) });
      const loadMs = Math.round(performance.now() - t);
      out[accelerator] = { load_ms: loadMs, ...(await bench(eye, pixels, { n: 10 })) };
      eye.dispose();
    } catch (e) {
      out[accelerator] = { error: String(e).slice(0, 200) };
    }
  }
  return out;
}

export function check(r) {
  console.log("EYE_BENCH " + JSON.stringify(r));
}
