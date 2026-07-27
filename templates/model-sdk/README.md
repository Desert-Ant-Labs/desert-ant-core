# __MODEL__

__DESCRIPTION__

On-device, private by default: the model runs locally on Apple platforms,
Android, and in the browser or Node.

## Install

```swift
// SwiftPM
.package(url: "https://github.com/Desert-Ant-Labs/__MODEL__.git", from: "0.1.0")
```
```kotlin
// Android
implementation("ai.desertant:__MODEL__:0.1.0")
implementation("ai.desertant:__MODEL__-tflite-resources:0.1.0")  // opt-in: bundle the model
```
```bash
npm i @desert-ant-labs/__MODEL__
```

## Use

```swift
let __MODEL__ = __PRODUCT__()
let result = try await __MODEL__.run("input")
```
```kotlin
val __MODEL__ = __PRODUCT__(context)
val result = __MODEL__.run("input")
```
```js
import { __PRODUCT__ } from "@desert-ant-labs/__MODEL__";
const __MODEL__ = await __PRODUCT__.load();
const result = await __MODEL__.run("input");
```

The model downloads on first use and is cached; Swift and Android can bundle it
instead for fully offline apps.

## Development

Build/test/publish run through mise; the shared pipeline lives in
[desert-ant-core](https://github.com/Desert-Ant-Labs/desert-ant-core).

```bash
mise run build          # every artifact
mise run test           # every suite
mise run set-version X.Y.Z && git tag vX.Y.Z && git push origin vX.Y.Z
```

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0).
