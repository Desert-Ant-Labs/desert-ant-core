# @desert-ant-labs/who

On-device speaker diarization for JavaScript that runs in the browser and in Node: who spoke when, as per-speaker turns with timestamps, in one pass over the audio. Speakers are numbered in the order they first speak, overlapping speech is marked for both, and recordings of any length are read in five-minute sections joined by voice. Audio stays local.

Two entries share one `Who` API:

- **`@desert-ant-labs/who`** (default): a WebAssembly pipeline with [LiteRT.js](https://www.npmjs.com/package/@litertjs/core) inference, for the **browser**, on the CPU. Safe to import during server-side rendering; `Who.load()` runs inference only in a browser or Web Worker.
- **`@desert-ant-labs/who/native`**: a prebuilt native core, Core ML on macOS and LiteRT on Linux, for **server-side inference** in Node. Import it from server-only code.

```bash
npm i @desert-ant-labs/who @litertjs/core   # browser
npm i @desert-ant-labs/who                  # Node, prebuilt native core
```

```js
import { Who } from "@desert-ant-labs/who";

const who = await Who.load();                   // downloads the 32 MB model on first use
const result = await who.diarize(file);         // a File or Blob, the bytes of an audio file, or samples

result.speakerCount;                            // 3
for (const turn of result.turns) {
  turn.speaker;                                 // 0, 1, 2: numbered in order of first appearance
  turn.start;                                   // 12.4, seconds from the start
  turn.end;                                     // 15.9
}
result.keepingSpeakers({ minimumShare: 0.05 }); // without the speakers under 5% of the recording
who.dispose();
```

`diarize` takes the bytes of an audio file (`File`, `Blob`, `ArrayBuffer`, `Uint8Array`), mono `Float32Array` samples at 16 kHz, or `{ samples, sampleRate }` at any rate. In the browser a file is decoded with Web Audio, so any format the browser plays works. In Node the portable decoder reads WAV; decode other formats first:

```js
import { Who } from "@desert-ant-labs/who/native";
import fs from "node:fs/promises";

const who = await Who.load();
const result = await who.diarize(await fs.readFile("call.wav"));
```

`JSON.stringify(result)` stores a diarization and `Diarization.fromJSON` restores it. Create one `Who` and reuse it; `dispose()` releases the model. The browser build runs the graphs on the CPU; pass `accelerator: "auto"` to `Who.load` to try WebGPU.

The full guide is in the [Who docs](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/docs/models/who.md).
