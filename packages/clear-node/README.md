# @desert-ant-labs/clear

On-device speech enhancement for JavaScript. Takes a noisy mono recording
(laptop mic, untreated room, traffic) and returns podcast-ready 48 kHz audio:
denoise and dereverb from a fine-tuned [DeepFilterNet 3][dfn], then loudness
normalization to a delivery target. Everything runs locally, so the audio never
leaves the device or browser.

[dfn]: https://github.com/Rikorose/DeepFilterNet

Two entries share one `Clear` API:

- **`@desert-ant-labs/clear`** (default): a WebAssembly pipeline with
  [LiteRT.js](https://www.npmjs.com/package/@litertjs/core) inference
  (XNNPACK-accelerated CPU by default, optional WebGPU), for the **browser**. It
  has no native dependencies, so a single import builds cleanly for every target
  of a multi-target bundler (Next.js, Remix, SvelteKit, Nuxt), including the
  browser bundle and the Client-Component SSR pass those frameworks render in
  Node. It is safe to *import* during server-side rendering, but LiteRT.js needs
  a browser (or Web Worker) to initialize, so `Clear.load()` runs inference only
  in the browser; calling it in plain Node throws an actionable error pointing
  you to `/native`.
- **`@desert-ant-labs/clear/native`**: a prebuilt native core (LiteRT on Linux,
  Core ML on macOS), for **server-side inference** in Node. No `@litertjs/core`,
  no build tools, no flags. Import it from server-only code (API routes, server
  actions, plain Node scripts). Do not import it from a component that also
  renders in the browser.

```bash
# Browser (default entry):
npm i @desert-ant-labs/clear @litertjs/core

# Server-side inference in Node (/native entry) needs no extra install:
npm i @desert-ant-labs/clear
```

## Usage

```ts
import { Clear } from "@desert-ant-labs/clear";           // browser
// import { Clear } from "@desert-ant-labs/clear/native"; // server-side Node

const clear = await Clear.load();          // downloads and caches on first use
const result = await clear.enhance(samples, 48_000);

result.samples;                // Float32Array, 48 kHz mono, whatever went in
result.measuredLUFS;           // integrated loudness of the input
result.measuredTruePeakDBFS;   // true peak of the output, after limiting
result.realtimeFactor;         // above 1 is faster than real time

clear.dispose();
```

Input can be a `Float32Array` or a plain array of numbers, at any sample rate;
the output is always 48 kHz mono.

## Mastering

By default the output is normalized to the Apple Podcasts target (-19 LUFS) with
a -1.5 dBTP ceiling, held by a look-ahead limiter rather than by turning the
whole file down to fit its loudest transient.

```ts
await clear.enhance(samples, 48_000, { targetLUFS: "spotify" });   // -14 LUFS
await clear.enhance(samples, 48_000, { targetLUFS: -23 });         // an explicit target
await clear.enhance(samples, 48_000, { targetLUFS: null });        // skip mastering
```

`LOUDNESS_PRESETS` carries the published platform targets (`applePodcasts`,
`spotify`, `youtube`, `broadcast`). Two more knobs are available:
`peakCeilingDBFS` (default -1.5) and `maxGainDB` (default 9), which bounds how
far a very quiet input is lifted so the model's noise floor does not come up
with it.

`strength` blends the enhanced signal against the original, for when full
denoising sounds too processed:

```ts
await clear.enhance(samples, 48_000, { strength: 0.7 });
```

## Self-hosting and progress

```ts
const clear = await Clear.load({
  modelBaseUrl: "/assets/clear/",     // browser: serve the files yourself
  directory: "/var/cache/clear",      // Node: adopt or download here
  onProgress: (fraction) => console.log(fraction),
});
```

The model repo and revision are pinned to this SDK version, so an install is
reproducible. Weights live on [Hugging
Face](https://huggingface.co/desert-ant-labs/clear).

## License

See [LICENSE.md](./LICENSE.md).
