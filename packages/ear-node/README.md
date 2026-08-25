# @desert-ant-labs/ear

On-device spoken language identification for JavaScript. Takes a recording and
names the language it is in, so an app can pick the right recognizer before it
starts transcribing. Everything runs locally, so the audio never leaves the
device or browser.

Two entries share one `Ear` API:

- **`@desert-ant-labs/ear`** (default): a WebAssembly pipeline with
  [LiteRT.js](https://www.npmjs.com/package/@litertjs/core) inference
  (XNNPACK-accelerated CPU by default, optional WebGPU), for the **browser**. It
  has no native dependencies, so a single import builds cleanly for every target
  of a multi-target bundler (Next.js, Remix, SvelteKit, Nuxt), including the
  browser bundle and the Client-Component SSR pass those frameworks render in
  Node. It is safe to *import* during server-side rendering, but LiteRT.js needs
  a browser (or Web Worker) to initialize, so `Ear.load()` runs inference only in
  the browser; calling it in plain Node throws an actionable error pointing you
  to `/native`.
- **`@desert-ant-labs/ear/native`**: a prebuilt native core (LiteRT on Linux,
  Core ML on macOS), for **server-side inference** in Node. No `@litertjs/core`,
  no build tools, no flags. Import it from server-only code (API routes, server
  actions, plain Node scripts). Do not import it from a component that also
  renders in the browser.

```bash
# Browser (default entry):
npm i @desert-ant-labs/ear @litertjs/core

# Server-side inference in Node (/native entry) needs no extra install:
npm i @desert-ant-labs/ear
```

## Use

```js
import { Ear } from "@desert-ant-labs/ear";          // browser
// import { Ear } from "@desert-ant-labs/ear/native"; // Node

const ear = await Ear.load();                        // downloads once, then cached
const detection = await ear.identify(samples, 16000);

detection.language      // "pt"
detection.confidence    // 0.98
detection.isReliable    // true

ear.dispose();
```

`samples` is mono `Float32Array` at any rate; audio is resampled, and 16 kHz
avoids the conversion.

## Branch on `isReliable`, not on `confidence`

```js
if (detection.isReliable) {
  transcribeWith(detection.language);
} else {
  askTheUser();            // or fall back to a general recognizer
}
```

`isReliable` is false when the top two candidates are too close to separate, and
false for the Nordic languages, which the model confuses with each other
confidently rather than uncertainly - so their probability does not reveal the
problem and a threshold on `confidence` cannot catch it. The flag is decided in
the model and crosses the boundary as a number, so every SDK reads the same
verdict.

The threshold behind it was set by sweeping it against 162 recordings: of the
answers above it, 98.5% route correctly, and on files in a language the primary
recognizer supports, 100% do.

## What it listens to

A file handed to a transcriber is not speech end to end, so `Ear` does not
listen to it end to end either. It ranks candidate windows by how much of their
loudness varies at syllable rate - speech rises and falls three to six times a
second and has gaps between words, music sustains, silence does not vary at all
- and listens to the three most speech-like.

Pass `windows` to change how many:

```js
await ear.identify(samples, 16000, { windows: 5 });
```

## Limits

- **Speech mixed under louder music** is read correctly about 60% of the time.
  Choosing better windows does not help; the model cannot read it.
- **Nordic languages** are not distinguished reliably, and `isReliable` is false
  for all of them rather than reporting one confidently.
- **Recordings shorter than thirty seconds** get a single window, so there is
  nothing to average and the answer is less certain than the number suggests.
- Multilingual recordings are reported as whichever language the chosen windows
  contain, not as a mixture.

## Licence

See LICENSE.md. The weights are published separately at
[`desert-ant-labs/ear`](https://huggingface.co/desert-ant-labs/ear) and derive
from `openai/whisper-tiny` (MIT), attributed there.
