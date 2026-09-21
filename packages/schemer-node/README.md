# @desert-ant-labs/schemer

On-device structured extraction for JavaScript that runs in the browser and in Node. Give Schemer text and a schema; it returns one typed value per field, in 13 languages. Nothing is generated: strings are literal spans of the input, labels are one of the values you declared, and a field the text does not state comes back `null`. Text stays local.

Two entries share one `Schemer` API:

- **`@desert-ant-labs/schemer`** (default): a WebAssembly pipeline with [LiteRT.js](https://www.npmjs.com/package/@litertjs/core) inference, for the **browser**. Safe to import during server-side rendering; `Schemer.load()` runs inference only in a browser or Web Worker.
- **`@desert-ant-labs/schemer/native`**: a prebuilt native core, Core ML on macOS and LiteRT on Linux, for **server-side inference** in Node. Import it from server-only code.

```bash
npm i @desert-ant-labs/schemer @litertjs/core   # browser
npm i @desert-ant-labs/schemer                  # Node, prebuilt native core
```

```js
import { Schemer } from "@desert-ant-labs/schemer";

const schemer = await Schemer.load();
const out = await schemer.extract("Coffee meeting at Blue Bottle with Dana and Priya, $18.50. Reimbursable.", {
  merchant: { type: "string", describe: "the shop or vendor" },
  amount: { type: "number", describe: "total paid", nullable: true, unit: "currency" },
  reimbursable: "boolean",
  category: { type: "label", values: ["food", "travel", "office"] },
  attendees: { type: "array", describe: "people present" },
});
// { merchant: "Blue Bottle", amount: 18.5, reimbursable: true, category: "food", attendees: ["Dana", "Priya"] }

schemer.dispose();
```

## Schemas

A schema is an object keyed by field name, or an array of `{ name, type, ... }` when you want the order explicit. A field is a type string (`"boolean"`) or `{ type, describe?, nullable?, ... }`:

| `type` | returns | options |
| --- | --- | --- |
| `"string"` | a literal span of the text, or `null` | |
| `"number"` | a number; `null` only if `nullable: true` | `min`, `max`, `unit` |
| `"boolean"` | `true`, `false` or `null` | |
| `"datetime"` | `"YYYY-MM-DDTHH:MM"`, or `null` | |
| `"label"` | one of `values` | `values`, at most 16 |
| `"array"` | literal spans, possibly `[]` | |
| `"array"` with `items: { type: "object", properties }` | objects, possibly `[]`; each holds only the properties the text states | `properties`, in either schema spelling |

`describe` is read by the model: "the shop or vendor" beats "merchant name". Relative dates ("tomorrow at 9:30") resolve against `now`, the device clock unless you pass `{ now: "2026-03-10" }` or a `Date` as the third argument. A `Date` is read as a day in the device's time zone.

Text past about 1,216 tokens is not read, and the result says so with a symbol key, so it never collides with a field: `if (out[TRUNCATED]) ...`, with `TRUNCATED` imported from the package. `Schemer.validate(schema)` throws the same `TypeError` as `extract` for a bad schema, with no model loaded.

## Loading the model

`Schemer.load()` downloads the model from the Hugging Face Hub ([`desert-ant-labs/schemer`](https://huggingface.co/desert-ant-labs/schemer)) at the SDK's pinned tag, verifies it, and caches it: about 230 MB. Pass `directory` (Node) or `modelBaseUrl` (browser) to use files you host yourself, and `onProgress` for download progress. The browser build also takes `litert`, `litertWasmDir`, and `accelerator`.

In the browser the model runs on the CPU in single-threaded WebAssembly: about 1.3 s a field for short text and 9 s a field for a long document. The native build runs Core ML on macOS and LiteRT's native CPU kernels on Linux, both far faster.

## Platforms

The native server build (`/native`) ships for linux-x64, linux-arm64, and darwin-arm64. Other Node platforms throw a clear error at `load()`; use the default WebAssembly build, the Swift package, or a browser for those.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for most apps; a commercial license is required at scale.
