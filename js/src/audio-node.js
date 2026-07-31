// Node audio-decode host for the wasm AudioIO backend (SSR / server-side). Node
// has no Web Audio, so this decodes with the pure-JS WAV codec and resampler
// (WAV only, matching Swift AudioIO's portable path). Installs the same
// `__DalAudioHost.decode` global as the browser host (audio.js); node-only
// (reads files through `node:fs`).

import { decodeWav, mixdownMono, resampleLinear } from "./wav.js";

/**
 * Install `globalThis.__DalAudioHost.decode(path, bytes, sampleRate)`, returning
 * a mono `Float32Array` at `sampleRate`. Under Node the Swift ModelStore hands a
 * cached file `path` (bytes null); a caller may also pass `bytes` directly.
 * Idempotent.
 */
export function installAudioHost() {
  globalThis.__DalAudioHost ??= {
    decode: async (path, bytes, sampleRate) => {
      let data = bytes;
      if (!data && path) {
        const fs = await import("node:fs");
        data = new Uint8Array(fs.readFileSync(path));
      }
      if (!data) throw new Error("__DalAudioHost.decode: no path or bytes");
      const { samples, sampleRate: srcRate, channels } = decodeWav(data);
      const mono = mixdownMono(samples, channels);
      return resampleLinear(mono, srcRate, sampleRate);
    },
  };
  return globalThis.__DalAudioHost;
}
