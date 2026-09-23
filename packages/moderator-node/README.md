# @desert-ant-labs/moderator

On-device NSFW image detection for JavaScript that runs in the browser and in Node. Moderator scores an image from 0 to 1 for nudity or sexual activity, tuned to pass swimwear and lingerie while flagging nude and sexual content. Images stay local.

Two entries share one `Moderator` API:

- **`@desert-ant-labs/moderator`** (default): a WebAssembly pipeline with [LiteRT.js](https://www.npmjs.com/package/@litertjs/core) inference, for the **browser**. Safe to import during server-side rendering; `Moderator.load()` runs inference only in a browser or Web Worker.
- **`@desert-ant-labs/moderator/native`**: a prebuilt native core, Core ML on macOS and LiteRT on Linux, for **server-side inference** in Node. Import it from server-only code.

```bash
npm i @desert-ant-labs/moderator @litertjs/core   # browser
npm i @desert-ant-labs/moderator                  # Node, prebuilt native core
```

```js
import { Moderator } from "@desert-ant-labs/moderator";

const moderator = await Moderator.load();
const { score, isNSFW, regions } = await moderator.analyze(image);
// regions: { nipples, genitals, buttocks, nude, sexAct }, each 0..1

moderator.dispose();
```

In the browser, `image` is anything `createImageBitmap` accepts (an `<img>`, a canvas, a `Blob`, an `ImageBitmap`) or an `ImageData`. In Node, pass decoded pixels as `{ data, width, height }` with RGB or RGBA bytes:

```js
import sharp from "sharp";
import { Moderator } from "@desert-ant-labs/moderator/native";

const { data, info } = await sharp("photo.jpg").rotate().raw().toBuffer({ resolveWithObject: true });
const result = await moderator.analyze({ data, width: info.width, height: info.height });
```

## Options

`analyze(image, { threshold, policy, quality })`:

- `threshold` (default `0.5`): score at or above which `isNSFW` is true.
- `policy`: `"standard"` (default) flags any nudity including a bare chest; `"allowTopless"` ignores a bare chest on its own.
- `quality`: `"fast"` scores one center crop (video frames), `"balanced"` four multiscale tiles, `"accurate"` (default) those tiles and their mirrors.

## Loading the model

`Moderator.load()` downloads the model from the Hugging Face Hub ([`desert-ant-labs/moderator`](https://huggingface.co/desert-ant-labs/moderator)) at the SDK's pinned tag, verifies it, and caches it. Pass `directory` (Node) or `modelBaseUrl` (browser) to use files you host yourself, and `onProgress` for download progress. The browser build also takes `litert`, `litertWasmDir`, and `accelerator` (`"wasm"`, `"webgpu"`, or `"webnn"`).

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for most apps; a commercial license is required at scale.
