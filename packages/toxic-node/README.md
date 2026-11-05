# @desert-ant-labs/toxic

On-device hate-speech triage for JavaScript that runs in the browser and in Node. Toxic scores a text for hate, abuse and threats, and says which group a hateful text targets. Text stays local.

Two entries share one `Toxic` API:

- **`@desert-ant-labs/toxic`** (default): a WebAssembly pipeline with [LiteRT.js](https://www.npmjs.com/package/@litertjs/core) inference, for the **browser**. Safe to import during server-side rendering; `Toxic.load()` runs inference only in a browser or Web Worker.
- **`@desert-ant-labs/toxic/native`**: a prebuilt native core, Core ML on macOS and LiteRT on Linux, for **server-side inference** in Node. Import it from server-only code.

```bash
npm i @desert-ant-labs/toxic @litertjs/core   # browser
npm i @desert-ant-labs/toxic                  # Node, prebuilt native core
```

```js
import { Toxic } from "@desert-ant-labs/toxic";

const toxic = await Toxic.load();
const result = await toxic.analyze("Go back to where you came from, nobody wants you here.");
result.isToxic              // true
result.content              // ["HATEFUL", "ABUSIVE"]
result.targets              // ["NATIONAL_ETHNIC_ORIGIN"]
result.scores.HATEFUL       // 0..1

toxic.dispose();
```

The text goes in as written: no lower-casing, no stripping. A text longer than the model's window (128 tokens, about 80 words) is read in overlapping windows, and each head keeps its highest score.

## What comes back

`analyze` returns every head's probability (`scores`), the threshold each head was judged at (`thresholds`), the heads at or above their thresholds (`flagged`), and two views of them: `content`, the heads that say what the text does (`HATEFUL`, `ABUSIVE`, `THREAT`), and `targets`, the heads that say which group a hateful text is about (`RACE`, `RELIGION`, `NATIONAL_ETHNIC_ORIGIN`, `SEXUAL_ORIENTATION`, `GENDER`, `DISABILITY`, `AGE`, `OTHER`), highest score first. `isToxic` is true when a content head fired. Read `targets` when `HATEFUL` fired.

## Options

`analyze(text, { thresholds })`:

- `thresholds`: a label to the threshold that replaces the model's default for that head, for example `{ HATEFUL: 0.3 }`. The defaults ship with the model, chosen on validation text; raise a threshold to flag less, lower it to flag more.

## Loading the model

`Toxic.load()` downloads the model from Hugging Face ([`desert-ant-labs/toxic`](https://huggingface.co/desert-ant-labs/toxic)) at the SDK's pinned tag, verifies it, and caches it. Pass `directory` (Node) or `modelBaseUrl` (browser) to use files you host yourself, and `onProgress` for download progress. The browser build also takes `litert`, `litertWasmDir`, and `accelerator` (`"wasm"`, `"webgpu"`, or `"webnn"`).

<!-- license:start -->
## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/). Free for most
apps, and a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

Third-party notices for the SDK: [`THIRD_PARTY_NOTICES.md`](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/THIRD_PARTY_NOTICES.md).

Third-party notices for the weights: [`THIRD_PARTY_NOTICES.md`](https://huggingface.co/desert-ant-labs/toxic/blob/main/THIRD_PARTY_NOTICES.md).
<!-- license:end -->
