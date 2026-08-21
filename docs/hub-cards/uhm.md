---
license: other
license_name: desert-ant-labs-source-available-1.0
license_link: https://license.desertant.com/1.0
language:
- en
- es
- fr
- de
- nl
tags:
- audio
- speech
- filler-detection
- disfluency
- on-device
- core-ml
- onnx
pipeline_tag: audio-classification
---

# Uhm: on-device filler-word detection

A frame-precise classifier that finds "uh", "um", "hmm", and other fillers in audio with 20 ms timestamps. Uhm runs on device, does not require ASR, and is trained on English with acoustic transfer to Spanish, French, German, and Dutch.

## Try it

- **Browser demo:** [`huggingface.co/spaces/desert-ant-labs/uhm-demo`](https://huggingface.co/spaces/desert-ant-labs/uhm-demo). Drop in any audio or video file and get a click-to-seek filler timeline.
- **Swift SDK:** [`github.com/Desert-Ant-Labs/uhm-swift`](https://github.com/Desert-Ant-Labs/uhm-swift). Downloads the Core ML model on first use and caches it locally.

## Files

| File | Format | Size | Use |
|---|---|---:|---|
| `uhm.mlmodelc/` | Core ML fp16 (compiled) | ~45 MB | iOS / macOS on-device |
| `uhm-web-fp16.onnx` | ONNX fp16 | ~51 MB | Browser, server, Python (`onnxruntime`) |
| `uhm.onnx` | ONNX fp32 | ~98 MB | Quantization-free reference |

`uhm.mlmodelc/` is a compiled Core ML model directory. The Swift SDK downloads it with the Hugging Face Hub snapshot API, so only changed files are re-fetched on model updates.

The shipped model is a DistilHuBERT fine-tune. It is the smaller and more precise Uhm runtime model; the older HuBERT-base tier is no longer published.

## Use

### Python (ONNX)

```python
from huggingface_hub import hf_hub_download
import onnxruntime as ort

path = hf_hub_download("desert-ant-labs/uhm", "uhm-web-fp16.onnx")
session = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
```

### Swift

```swift
import Uhm

let uhm = try await Uhm()
let result = try await uhm.analyze(audioURL: url)
for filler in result.fillers {
    print(filler.start, filler.end, filler.confidence, filler.type ?? .other)
}
```

## Inputs and outputs

- **Input:** 16 kHz mono audio, up to 30-second windows.
- **Output:** per-frame softmax over 6 classes, one prediction every 20 ms.
- **Class indices:** `0 = not_filler, 1 = uh, 2 = um, 3 = hmm, 4 = and, 5 = other`.

Core ML input shape `(1, 480000)` float32; output `(1, 1499, 6)`. Requires iOS 17 / macOS 14 or newer.

## Performance

Warm on-device runs on the published fp16 Core ML model:

| Device | Realtime factor |
|---|---:|
| iPhone 17 Pro | ~296× |
| iPhone 15 Pro | ~169× |
| iPad Pro M4 | ~279× |

Realtime factor = audio duration ÷ analyze time; model load excluded.

## Limitations

- Trained on English; non-English performance is by acoustic transfer and has not been measured against per-language ground truth.
- Best on podcast / meeting / talking-head audio. Heavy background music, laughter, or multi-speaker overlap degrades quality.
- Type labels (`uh` / `um` / `hmm` / `and` / `other`) are secondary. Trust filler vs. not-filler more than the specific subtype.

## Built on

- Base architecture and pretrained weights: [`ntu-spml/distilhubert`](https://huggingface.co/ntu-spml/distilhubert), a distilled variant of [`facebook/hubert-base-ls960`](https://huggingface.co/facebook/hubert-base-ls960). Apache 2.0.
- Public fine-tuning audio: [AMI Meeting Corpus](https://huggingface.co/datasets/edinburghcstr/ami) (`edinburghcstr/ami`, IHM split). CC BY 4.0, Edinburgh CSTR.
- Internal video content created by the Desert Ant Labs team.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for
most apps; a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

## Citation

```bibtex
@software{uhm_2026,
  title  = {Uhm: on-device filler-word detection},
  author = {Desert Ant Labs},
  year   = {2026},
  url    = {https://huggingface.co/desert-ant-labs/uhm},
}
```

---

© 2026 Desert Ant Labs · <https://desertant.com>
