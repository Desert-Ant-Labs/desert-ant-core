// Opt-in: DAL_BROWSER_CASE=browser-bench.js node js/test/browser/run.mjs --only uhm prints one UHM_BENCH JSON line.

export async function run({ Uhm, SAMPLE_RATE }, { litert, litertWasmDir }) {
  const seconds = 300;
  const samples = new Float32Array(SAMPLE_RATE * seconds);
  for (let n = 0; n < samples.length; n++) {
    const t = n / SAMPLE_RATE;
    samples[n] = (0.5 + 0.5 * Math.sin(2 * Math.PI * 4 * t)) * 0.2 * Math.sin(2 * Math.PI * 180 * t);
  }
  const out = { userAgent: navigator.userAgent, threads: self.crossOriginIsolated === true, audio_seconds: seconds };
  for (const accelerator of ["default", "wasm", "webgpu"]) {
    try {
      let t = performance.now();
      const uhm = await Uhm.load({ litert, litertWasmDir, ...(accelerator === "default" ? {} : { accelerator }) });
      const loadMs = Math.round(performance.now() - t);
      t = performance.now();
      await uhm.detect(samples, SAMPLE_RATE);
      const firstMs = Math.round(performance.now() - t);
      const runs = [];
      for (let i = 0; i < 3; i++) {
        t = performance.now();
        await uhm.detect(samples, SAMPLE_RATE);
        runs.push(performance.now() - t);
      }
      runs.sort((a, b) => a - b);
      out[accelerator] = { load_ms: loadMs, first_ms: firstMs, warm_ms_median: Math.round(runs[1]), realtime_factor: +(seconds * 1000 / runs[1]).toFixed(1) };
      uhm.dispose();
    } catch (e) {
      out[accelerator] = { error: String(e).slice(0, 200) };
    }
  }
  return out;
}

export function check(r) {
  console.log("UHM_BENCH " + JSON.stringify(r));
}
