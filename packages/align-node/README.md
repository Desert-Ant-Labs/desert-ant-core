# @desert-ant-labs/align

On-device word-timestamp refinement for JavaScript, server-side in Node. Give Align the audio and the words your recognizer already produced, in any of nine languages, and it returns the same words with their start and end times corrected against the waveform. The audio stays local.

Align refines what you already have, so it replaces nothing: keep Whisper, Parakeet, SpeechAnalyzer or whatever else you run, and hand its output here when the word times are not tight enough to caption, to cut on, or to build a karaoke view from.

## Node-only, and why

This package is **Node-only**, and that is a property of the model rather than a gap. The refiner is a cascade of two graphs, a coarse stage that finds each boundary and a fine stage that sharpens it, and the WebAssembly host compiles one model per module. Two graphs do not fit in one module, so there is no browser build to ship.

The default entry still exists, and it is the reason the package is safe to depend on from isomorphic code: it imports cleanly everywhere, including the Client-Component SSR pass that Next.js, Remix, SvelteKit and Nuxt render in Node, and `Align.load()` outside `/native` throws an actionable error that points back here. Lifting the restriction is a change to the host contract, not a patch to this package.

## Install

```bash
npm i @desert-ant-labs/align
```

The native core is prebuilt, Core ML on macOS and LiteRT on Linux, with no build tools and no flags. Import it from server-only code: an API route, a server action, a queue worker, a plain Node script.

```js
import { Align } from "@desert-ant-labs/align/native"; // server only

const align = await Align.load();

const words = [
  { text: "hello", start: 0.40, end: 0.71 },
  { text: "world", start: 0.80, end: 1.30 },
];
const refined = await align.refine(samples, 16000, words, { language: "en" });
// [{ text: "hello", start: 0.412, end: 0.688, refined: true }, ...]

align.dispose(); // release the model
```

`samples` is mono float32 PCM. Any sample rate is accepted and resampled internally. Every key you put on a word comes back untouched, so a word that carried a confidence or a speaker id still carries it; only `start` and `end` are replaced, and `refined` is added.

`refined` is per word. It is `false` when the correction would have been structurally invalid, or when the search ran into the edge of the audio, and that word keeps the times you passed in. A result is therefore never worse than its input.

## Languages

Nine: `de`, `en`, `es`, `fr`, `it`, `ja`, `ko`, `pt`, `zh`. Read them from `Align.languages`, and check a code before you call:

```js
Align.isSupported("pt-BR"); // true, only the first two letters matter
Align.isSupported("sv");    // false
```

An unsupported language is a **passthrough, not an error**: `refine` returns your words with their original times and `refined: false` on each. That keeps a mixed-language pipeline from needing a branch, but it also means a silent no-op is possible, so check `isSupported` when you care which one you got.

The same three members are also on a loaded instance, so code holding an `align` needs no reference to the class: `align.languages`, `align.isSupported(code)`, `align.sdkVersion`.

## Loading the model

`Align.load()` downloads the model files from the Hugging Face Hub ([`desert-ant-labs/align`](https://huggingface.co/desert-ant-labs/align)) at the SDK's pinned revision on first use, verifies them, and caches them under the OS cache directory. Nothing model-sized ships in the npm tarball.

On a server you will usually pre-place the files instead:

```js
const align = await Align.load({ directory: "/opt/models/align" });
```

A directory that already holds the model files is used offline, as-is. An empty one is downloaded into. `Align.load()` also takes `cacheRoot` to move the managed cache, and `onProgress` for download progress as a fraction from 0 to 1. `align.isDownloaded()` answers whether the model is usable with no network.

Which file format the core opens is its own business: it resolves the artifacts for the host it is running on from the catalog, so your code never names a model file.

## Usage metering

Two optional per-call knobs, both accepted by `refine`:

- `deviceId` attributes a call to a specific end-user device. It is read per call, so a multi-tenant host can serve many devices from one loaded model.
- `group` bills several calls as one. Get an id from `withCallGroup`, which releases it when the body settles:

```js
await align.withCallGroup(async (group) => {
  for (const segment of segments) {
    await align.refine(segment.samples, 16000, segment.words, { language: "en", group });
  }
});
```

## Platforms

The native core ships for `darwin-arm64`, `linux-x64` and `linux-arm64`. Any other Node platform throws a clear error at `load()`, naming the targets that exist. Use the Swift package there instead.

If you import this package from a framework that bundles server code, mark it external so the bundler leaves the native binary alone. In Next.js:

```js
// next.config.js
module.exports = { serverExternalPackages: ["@desert-ant-labs/align"] };
```

## More

The model page is the full usage guide for every SDK: [docs/models/align.md](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/docs/models/align.md).

## License

See `LICENSE.md`. Free for most apps; a commercial license is required at scale: <https://license.desertant.com/1.0>.
