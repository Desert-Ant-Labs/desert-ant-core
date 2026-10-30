# @desert-ant-labs/eye

On-device photo understanding for JavaScript that runs in the browser and in Node: find and filter the photos you want. One call tags a photo with what it is (screenshot, receipt, selfie), what is in it (dog, beach, 558 scenes), how it came out (blurry, eyes closed), who is in it (group shot, portrait) and whether it is sensitive. Every tag has a confidence where 0.5 is the recommended cutoff and 0.9 a strict one. Images stay local.

Two entries share one `Eye` API:

- **`@desert-ant-labs/eye`** (default): a WebAssembly pipeline with [LiteRT.js](https://www.npmjs.com/package/@litertjs/core) inference, for the **browser**: on the GPU through WebGPU when the browser has it, else on the CPU. Safe to import during server-side rendering; `Eye.load()` runs inference only in a browser or Web Worker.
- **`@desert-ant-labs/eye/native`**: a prebuilt native core, Core ML on macOS and LiteRT on Linux, for **server-side inference** in Node. Import it from server-only code.

```bash
npm i @desert-ant-labs/eye @litertjs/core   # browser
npm i @desert-ant-labs/eye                  # Node, prebuilt native core
```

```js
import { Eye, Tag } from "@desert-ant-labs/eye";

const eye = await Eye.load();
const photo = await eye.analyze(image);
if (photo.has(Tag.dog) && !photo.has(Tag.blurry)) keep(photo);
photo.tags();               // ["photo", "beach", "people", "smiling", ...]
photo.has(Tag.sensitive, "strict");
photo.bestCrop(1);          // a square thumbnail

const groups = Eye.duplicates(library, { dates });   // near-duplicates, best first
eye.dispose();
```

`JSON.stringify(photo)` stores an analysis and `Analysis.fromJSON` restores it, so a library can be filtered later without the model. `options.parts` picks what to compute (`"photo"`, `"layout"`, `"faces"`, `"sharpness"`; all by default); tags that need a part left out are absent. In the browser, `image` is anything `createImageBitmap` accepts or an `ImageData`. In Node, pass decoded pixels as `{ data, width, height }` with RGB or RGBA bytes, upright:

```js
import sharp from "sharp";
import { Eye } from "@desert-ant-labs/eye/native";

const { data, info } = await sharp("photo.jpg").rotate().raw().toBuffer({ resolveWithObject: true });
const photo = await eye.analyze({ data, width: info.width, height: info.height });
```

The full guide is in the [Eye docs](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/docs/models/eye.md).

<!-- license:start -->
## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/). Free for most
apps, and a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

Third-party notices for the SDK: [`THIRD_PARTY_NOTICES.md`](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/THIRD_PARTY_NOTICES.md).

Third-party notices for the weights: [`THIRD_PARTY_NOTICES.md`](https://huggingface.co/desert-ant-labs/eye/blob/main/THIRD_PARTY_NOTICES.md).
<!-- license:end -->
