# @desert-ant-labs/face

On-device face matching for JavaScript, in the browser and in Node. Find the faces in a photo, group a library into people, let the user name and fix them, and tell who is in a new photo. No face leaves the device.

Two entries share one `Face` API:

- `@desert-ant-labs/face` (default) runs a WebAssembly pipeline with [LiteRT.js](https://www.npmjs.com/package/@litertjs/core) inference in the browser. You can import it during server-side rendering; `Face.load()` runs inference only in a browser or Web Worker.
- `@desert-ant-labs/face/native` runs a prebuilt native core in Node for server-side inference: Core ML on macOS and LiteRT on Linux.

```bash
npm i @desert-ant-labs/face @litertjs/core   # browser
npm i @desert-ant-labs/face                  # Node, prebuilt native core
```

```js
import { Face } from "@desert-ant-labs/face";

const face = await Face.load();
const library = await face.library();                 // or face.library(saved)
await library.add(await face.faces(image), photoId, { date });

for (const person of await library.people({ prominent: true })) show(person);
await library.name(person.id, "Noor");
await library.reject(faceId, person.id);               // "This is not Noor"
await library.newPerson(faceId, "Ana");                // "This is Ana", someone new
(await library.personFor(newFace.faceprint))?.name;    // "Noor"

const saved = await library.save();                    // JSON: store it, or keep the rows in your own database
```

`library.takeChanges()` returns the face records whose person changed, one row of your own faces table each, and `face.library({ faces, names })` rebuilds a library from your rows. `faceprint.isSamePerson(other)` and `Face.matches(reference, faceprints)` compare stored faceprints without the model. In the browser, `image` is anything `createImageBitmap` accepts or an `ImageData`. In Node, pass decoded, upright pixels as `{ data, width, height }` with RGB or RGBA bytes:

```js
import sharp from "sharp";
import { Face } from "@desert-ant-labs/face/native";

const { data, info } = await sharp("photo.jpg").rotate().raw().toBuffer({ resolveWithObject: true });
const faces = await face.faces({ data, width: info.width, height: info.height });
```

The full guide is in the [Face docs](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/docs/models/face.md).

<!-- license:start -->
## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/). Free for most
apps, and a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

Third-party notices for the SDK: [`THIRD_PARTY_NOTICES.md`](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/THIRD_PARTY_NOTICES.md).
<!-- license:end -->
