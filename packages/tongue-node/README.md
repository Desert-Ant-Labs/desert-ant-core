# tongue — JavaScript / TypeScript SDK

On-device language identification for short text, across 84 languages. Runs in the
browser and in Node from one import.

```ts
import { Tongue } from "@desert-ant-labs/tongue";

const tongue = await Tongue.load();
tongue.detect("kann ich das haben").language;   // "de"
tongue.detect("안녕하세요").language;             // "ko"
```

**No wasm, no inference runtime, no dependencies.** A detection is an int8
embedding gather, a sum, one 59×32 matmul and a masked softmax — a few thousand
multiply-adds in plain JavaScript. That is why this package has a single entry
point where `emo-js` needs separate browser and Node builds: there is no runtime to
swap, only two ways to read 2 MB of weights.

## Install

```
npm i @desert-ant-labs/tongue
```

Node ≥18, or any modern browser.

```ts
// Node: reads the bundled weights from the package directory.
const tongue = await Tongue.load();

// Browser: serve tongue_int8.bin and tongue_meta.json and point at them.
const tongue = await Tongue.load({ from: "/models/tongue" });

// Or supply the bytes yourself.
const tongue = Tongue.fromBytes(metadata, weightBytes);
```

## Saying "I don't know"

Short input is often genuinely undecidable, and the SDK says so rather than
guessing. Reliability is keyed off evidence — input length and how far the top
candidate leads the runner-up — not raw softmax confidence, which is badly
overconfident on two words.

```ts
const detection = tongue.detect("la casa");
detection.isTooCloseToCall;   // true — equally Italian and Spanish
detection.reliability;        // "tentative"
detection.candidates;         // [it 0.31, es 0.29, …]
```

Present both when `isTooCloseToCall` is set. Treat `"tentative"` as "unknown"
rather than as an answer, and ask for more text where the product allows it.

## API

| | |
|---|---|
| `Tongue.load(options?)` | load the model; `options.from` is a directory or base URL |
| `Tongue.fromBytes(metadata, bytes)` | load from bytes you already have |
| `detect(text, topK?)` | `Detection` |
| `Detection.language` | top candidate, or `null` on empty input |
| `Detection.candidates` | `Prediction[]` with probabilities |
| `Detection.reliability` | `"confident"` · `"likely"` · `"tentative"` · `"empty"` |
| `Detection.isTooCloseToCall` | top two within 0.12 |
| `Detection.route.verdict` | `"decisive"` (script alone settled it) · `"narrowing"` · `"ambiguous"` |

`normalize`, `route`, `fnv1a` and `buckets` are also exported, for anyone
reproducing the feature pipeline.

## CommonJS and TypeScript

The package is ESM-only. `require()` of it works natively on Node 20.19+, so a
CJS server needs no changes at runtime. TypeScript in a CJS project should set
`"moduleResolution": "nodenext"` (TS 5.8+) — the older `node16` setting rejects
the import with TS1479 even though the emitted `require()` runs. On Node older
than 20.19, use a dynamic `import()`.

## Serving the model in a browser

On Node the weights load out of the package with no configuration. A bundler does
not serve files from `node_modules`, so in a browser you serve the two model files
yourself and point `load` at them:

```ts
const tongue = await Tongue.load({ from: "/models/tongue" });
```

Both files are exported, so a bundler can fingerprint and hash them rather than
needing a copy step:

```ts
import binUrl from "@desert-ant-labs/tongue/model/tongue_int8.bin?url";   // Vite
import metaUrl from "@desert-ant-labs/tongue/model/tongue_meta.json?url";
```

Or copy `node_modules/@desert-ant-labs/tongue/dist/tongue_{int8.bin,meta.json}`
into your static directory as a build step.

Calling `Tongue.load()` with no `from` in a browser resolves against the page URL,
which on a single-page app hits the history fallback and returns `index.html`. The
error says so explicitly if it happens.

## The cross-platform contract

The normalizer, hasher and router are a **frozen specification** shared with the
Python reference and the Swift and Kotlin SDKs. `test/golden.test.js` replays the
same vector files all of them do, including whole-bag hasher equality:

```
npm test
```

Regenerate the Unicode tables rather than editing them:

```
python3 scripts/gen_ts_tables.py --reference ../tongue-training
```

## Model

Weights, benchmarks and limitations: [huggingface.co/desert-ant-labs/tongue](https://huggingface.co/desert-ant-labs/tongue).
Live demo: [desert-ant-labs-tongue-demo.static.hf.space](https://desert-ant-labs-tongue-demo.static.hf.space/).

Read the model card's failure modes before deploying: one or two words is often
genuinely ambiguous, Malay and Indonesian are not reliably separable at this size,
Mongolian works only in the traditional script, and brand names and version
strings are not language at all.

## Licence

[Desert Ant Labs Source-Available Licence](https://license.desertant.com/1.0).
Free for most apps; a commercial licence is required at scale.
