# @desert-ant-labs/uhm

Find every "uh", "um", and "hmm" in a recording, in the browser or in Node. Uhm marks each filler with a start, an end, and a confidence, at 20ms resolution, without a transcript. The audio never leaves the device.

The package has two entries with the same `Uhm` API:

- `@desert-ant-labs/uhm` is the default entry, for the browser. It runs on WebAssembly and [LiteRT.js](https://www.npmjs.com/package/@litertjs/core), and has no native dependencies, so one import builds for every target of Next.js, Remix, SvelteKit, or Nuxt. You can import it during server-side rendering, but `Uhm.load()` only runs in a browser or a Web Worker. In plain Node, `Uhm.load()` throws an error that points to `/native`.
- `@desert-ant-labs/uhm/native` is for inference in Node. It runs a prebuilt native core: LiteRT on Linux and Core ML on macOS. Import it only from server code, such as API routes, server actions, and scripts.

```bash
# Browser
npm i @desert-ant-labs/uhm @litertjs/core

# Node
npm i @desert-ant-labs/uhm
```

## Usage

```js
import { Uhm } from "@desert-ant-labs/uhm";           // browser
// import { Uhm } from "@desert-ant-labs/uhm/native"; // Node

const uhm = await Uhm.load();                         // downloads once, then cached
const result = await uhm.detect(samples, 16000);

result.fillers          // [{ start: 3.12, end: 3.40, confidence: 0.82, type: null }]
result.audioDuration    // seconds

uhm.dispose();
```

`samples` is mono `Float32Array` audio at any sample rate. The SDK resamples to 16kHz. In the browser, decode a file with the Web Audio API and pass `getChannelData(0)`. In Node, decode a WAV file with `decodeWav` from `@desert-ant-labs/core/audio` and pass the result through `mixdownMono(samples, channels)`.

## Precision and recall

`bias` sets the confidence threshold. Use `"precision"` when you cut fillers automatically, and `"recall"` when someone reviews each filler before the cut.

```js
await uhm.detect(samples, 16000, { bias: "precision" });   // 0.75
await uhm.detect(samples, 16000, { bias: "balanced" });    // 0.65, the default
await uhm.detect(samples, 16000, { bias: "recall" });      // 0.50
await uhm.detect(samples, 16000, { minConfidence: 0.7, minDurationSec: 0.08 });
```

## Cutting fillers without clipping words

A recognizer's word timings often overlap the fillers. To cut fillers out of a recording, pass your transcript's words with the audio. Uhm drops a word that the recognizer wrote for the filler itself, trims a word that runs into a filler, and splits a word that contains a filler. Cut at the returned word ranges, and every real word keeps its audio.

```js
const result = await uhm.detect(samples, 16000, {
  words: [{ start: 0.42, end: 0.81, text: "think" }, { start: 0.81, end: 1.05, text: "um" }],
});
result.words
```

## Self-hosted files and progress

```js
const uhm = await Uhm.load({
  modelBaseUrl: "/assets/uhm/",        // browser: serve the model files yourself
  directory: "/var/cache/uhm",         // Node: use or download the files here
  onProgress: (fraction) => console.log(fraction),
});
```

Each SDK version loads one pinned revision of the [model weights](https://huggingface.co/desert-ant-labs/uhm), so the same install always runs the same model.

## Limits

- Uhm is trained on English. Uhm detects fillers in Spanish, French, German, and Dutch by acoustic transfer, and we haven't measured that against per-language ground truth.
- Uhm works best on podcast, meeting, and talking-head audio. Heavy music, laughter, and overlapping speakers lower the detection quality.
- The filler type (`uh`, `um`, `hmm`) is available only on Apple platforms. In the browser and on Linux, `type` is `null`. On macOS, `/native` reports the type.

<!-- license:start -->
## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/). Free for most
apps, and a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

Third-party notices for the SDK: [`THIRD_PARTY_NOTICES.md`](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/THIRD_PARTY_NOTICES.md).

Third-party notices for the weights: [`THIRD_PARTY_NOTICES.md`](https://huggingface.co/desert-ant-labs/uhm/blob/main/THIRD_PARTY_NOTICES.md).
<!-- license:end -->
