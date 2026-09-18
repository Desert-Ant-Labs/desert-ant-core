# @desert-ant-labs/voz

On-device speech recognition for JavaScript that runs in the browser and in Node. Give Voz audio and it returns a transcript with a start and an end on every word, across 25 languages. Audio stays local: nothing is uploaded, and there is no API key.

One entry, `@desert-ant-labs/voz`, and one `Voz` API. Unlike this project's other models there is no `/native` subpath: Voz has no native Node core, so the browser and the server run the same WebAssembly pipeline - the same windowing, lane-batched decode and splice as the Swift SDK - over ONNX Runtime.

```bash
# Browser
npm i @desert-ant-labs/voz onnxruntime-web

# Node
npm i @desert-ant-labs/voz onnxruntime-node
```

In the browser you install the runtime and nothing else. It is imported on
demand, the way `@litertjs/core` is for this project's other models, and
bundlers split it into its own chunk, so a page that never transcribes never
downloads it.

```js
import { Voz } from "@desert-ant-labs/voz";

const voz = await Voz.load();
const result = await voz.transcribe(file);   // a File, Blob, ArrayBuffer, or samples

result.text;            // "the transcript, as one string"
result.words[0];        // { text: "the", start: 0.08, end: 0.24 }
result.realtimeFactor;  // seconds of audio per second of wall clock
```

The file is read in pieces as the model works through it, so a five-minute
recording and a five-hour one cost the same memory. See
[Memory](#memory) for what that means in numbers.

Under Node you pass the runtime, because there it is `onnxruntime-node`, a
native addon. A package that imports one of those cannot be bundled for a
server, so this one does not.

```js
import { Voz } from "@desert-ant-labs/voz";
import * as ort from "onnxruntime-node";

const voz = await Voz.load({ ort });
```

Passing `ort` works in the browser too, for an app that already bundles a
runtime or wants a build other than `onnxruntime-web/webgpu`.

The bundle is downloaded from the Hugging Face Hub on first use and cached (the
Cache API in a browser, disk in Node), so a reload does not fetch it again.
Nothing model-sized ships in the npm tarball.

## Word timestamps

Every word carries `start` and `end` in seconds from the beginning of the audio,
which is what subtitles, transcript highlighting and clip-finding need:

```js
const { words } = await voz.transcribe(file);

for (const { text, start, end } of words) {
  console.log(`${start.toFixed(2)} -> ${end.toFixed(2)}  ${text}`);
}
```

Times come from the frame that emitted each word rather than from a second
alignment pass, so they cost nothing extra. Their resolution is one encoder
frame, 80 ms.

## What you can pass to transcribe

| Input | What happens |
| --- | --- |
| `File`, `Blob` | Streamed: read in pieces, any container WebCodecs can decode |
| a path (Node 20+) | Streamed, the same way |
| `ArrayBuffer`, `Uint8Array` | Decoded whole, since the bytes are already in memory |
| `Float32Array` | Taken as mono 16 kHz samples |
| `{ samples, sampleRate }` | Resampled to 16 kHz |

A browser can hand over a `<input type="file">` file directly:

```js
input.addEventListener("change", async () => {
  const result = await voz.transcribe(input.files[0], {
    onProgress: (fraction) => console.log(`${Math.round(fraction * 100)}%`),
  });
  console.log(result.text);
});
```

Under Node, a path streams the same way a `File` does, which needs Node 20 or
newer (`fs.openAsBlob`). WebCodecs is what decodes compressed audio, so on a
Node build without it, convert to WAV first - `ffmpeg -i in.mp4 -ac 1 -ar 16000
out.wav` - which streams everywhere.

If a decoder ever returns less audio than the container says it holds, that is
reported rather than transcribed: `decodeAudioData` can return a short buffer
with no error, and a transcript that quietly stops a minute in is worse than a
failure. In a video file, where the audio track is allowed to be shorter than
the picture, it is a warning instead.

## Memory

Constant in the length of the recording, which is the point of the streaming
path above. Measured in Chromium on an M5, peak resident for the whole browser:

| audio | peak |
| --- | --- |
| 1 minute | 2.4 GB |
| 29 minutes | 2.7 GB |
| 29 minutes, before streaming | 7.7 GB |

About 1.2 GB of that floor is the model: 349 MB of weights, and roughly 900 MB
that ONNX Runtime keeps for the compiled session (measured, and not something
this package can configure away). The rest is the browser itself. What matters
is the shape: the audio no longer contributes, so length is free.

## Where it runs

In the browser the encoder runs on **WebGPU** and, where the browser exposes
**WebNN** (Chromium today), the decode step runs on the Neural Engine. Both are
detected; `Voz.load({ webnn: false })` forces WebGPU alone.

Speed, ten minutes of audio: about 125x real time in Chromium on an M5, 38x on
an M1, 255x on an M3 Ultra, and about 35x in Safari. Word error rate is level
with the Core ML build the Apple SDK uses (2.83% against 2.66% over 300
LibriSpeech utterances, a difference a paired bootstrap cannot distinguish).

Under Node, `onnxruntime-node` runs on the CPU. That is the right choice for
transcribing a file on a server, and it is slower per second of audio than the
browser path on the same machine, because a browser reaches the GPU and
`onnxruntime-node`'s default execution provider does not.

The page needs no `SharedArrayBuffer` and no cross-origin isolation: the runtime
is configured for a single wasm thread, which measured identical on Chromium and
avoids a WebKit JIT pathology that costs 15% in Safari.

## Loading the model

`Voz.load()` takes:

| Option | Default | |
| --- | --- | --- |
| `ort` | onnxruntime-web in the browser | an ONNX Runtime module of your own; required under Node |
| `ep` | `"auto"` | `"webgpu"` or `"wasm"` to override where the graphs run |
| `modelBaseUrl` | the Hub | serve the bundle yourself; must end in `/` |
| `revision` | the SDK's pin | a different revision of the weights |
| `webnn` | detected | run the decode step on WebNN |
| `wasmDir` | the runtime's own | where onnxruntime-web's `.wasm` files are served from |
| `onProgress` | none | download progress, as a fraction |
| `cache` | `true` | cache the downloaded bundle |

To serve the weights yourself, copy the `web/` directory of the weights repo
next to your app and point `modelBaseUrl` at it. `meta.json` names the rest, so
there is no file list to keep in sync here.

One instance holds three compiled graphs and about 1.2 GB of resident weights,
so load it once and reuse it. A transcription holds the instance for its whole
run, and concurrent calls queue rather than interleave.

## Requirements

- A browser with WebGPU. Tested on Chromium 135+ and Safari 26+. A browser
  whose adapter cannot compile the encoder's f16 shaders - which is what a
  machine with no GPU exposes - runs on the CPU instead, correctly and much
  more slowly.
- Node 20+ for streaming from a path, with `onnxruntime-node` installed.

## License

The SDK is source-available under the license in this package. The model weights
carry their own license on the Hub.
