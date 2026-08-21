---
license: other
license_name: desert-ant-labs-source-available-1.0
license_link: https://license.desertant.com/1.0
language:
- en
tags:
- image
- image-classification
- content-moderation
- nsfw
- on-device
- core-ml
- onnx
pipeline_tag: image-classification
---

# Moderator, on-device NSFW detection

Moderator returns a single NSFW score from 0 to 1: the probability an image contains nudity or sexual activity. Threshold it (default 0.5) and you have your answer. Designed to pass real swimwear and lingerie photos while flagging real nude and sexual content. Apple-platform first; ships as Core ML at fp16 for size and as ONNX for cross-platform use.

Per-region detail (nipples, genitals, buttocks, nudity, sexual activity) is available for policies that need it, for example allow-topless. See [Outputs](#inputs-and-outputs).

## Try it

- **iOS / macOS:** [`moderator-swift`](https://github.com/Desert-Ant-Labs/moderator-swift), the Swift SDK with a built-in demo app.

## Files

| File | Format | Size | Use |
|---|---|---:|---|
| `moderator.mlpackage.zip` | Core ML mlpackage (fp16) | ~18 MB | iOS / macOS on-device, default |
| `moderator_6bit.mlpackage.zip` | Core ML mlpackage (6-bit palettized) | ~7 MB | iOS / macOS, size-constrained builds |
| `moderator.onnx` | ONNX (fp32) | ~35 MB | Browser, server, Python via `onnxruntime` |

The fp16 build is the default and matches the fp32 ONNX within fp16 rounding. The 6-bit build is the smallest that holds accuracy; 4-bit and below collapse and are not shipped.

## Use

### Swift (iOS / macOS)

```swift
import Moderator

let moderator = try await Moderator()
let result = try await moderator.analyze(image)

print(result.score)      // 0...1, the NSFW score
print(result.isNSFW)     // Bool, score >= threshold (default 0.5)

// Optional per-region detail:
print(result.regions.nude, result.regions.sexAct,
      result.regions.nipples, result.regions.genitals, result.regions.buttocks)
```

See [`moderator-swift`](https://github.com/Desert-Ant-Labs/moderator-swift) for options, thresholds, and the demo app.

### ONNX (Python / Node / Web)

```python
import onnxruntime as ort
import numpy as np

sess = ort.InferenceSession("moderator.onnx")
# image: float32 [B, 3, 384, 384], RGB, ImageNet-normalized
heads = sess.run(None, {"image": image})   # 5 region probabilities
nsfw_score = np.max(heads, axis=0)          # the single NSFW score
is_nsfw = nsfw_score >= 0.5
```

## Inputs and outputs

The [Swift SDK](https://github.com/Desert-Ant-Labs/moderator-swift) handles all of this for you. For direct ONNX or Core ML use:

### Input

One tensor named `image`, shape `[1, 3, 384, 384]`, RGB, NCHW. Core ML takes `float16`, ONNX takes `float32`. Preprocess each image:

1. Resize the short side to 384, center-crop to 384x384.
2. Scale pixels to `[0, 1]`.
3. Normalize: `mean = [0.485, 0.456, 0.406]`, `std = [0.229, 0.224, 0.225]`.

One forward pass per image (no test-time augmentation baked in).

### Output

The **NSFW score**, from 0 to 1, thresholded at 0.5 by default. It is the max of five region heads, which are also returned individually for finer policies (for example, allow-topless ignores `nipples_visible`):

- `nude`
- `sex_act`
- `nipples_visible`
- `genitals_visible`
- `buttocks_visible`

### Passes

Run one crop for speed, or more crops (taking the max score) for higher recall:

| Crops per image | Recall | Specificity |
|---|---:|---:|
| 1 (center) | 74% | 97% |
| 4 (multi-scale tiles) | 84% | 95% |
| 8 (multi-scale tiles + flips) | 88% | 94% |

- **Single images:** run 8 crops for best recall.
- **Video:** 1 crop per frame is cheapest and most precise, and sampling across frames recovers recall. Use the 4-tile pass if you need higher per-frame recall.

## Model

- **Backbone:** MobileNetV4-Conv-Medium (8.4M params), Apache 2.0.
- **Head:** 2-layer MLP (1280 to 512 to 5), L2-normalized features.

## Training data: 100% clean

This is the rare NSFW model with fully controlled data provenance. Nothing is scraped from the open internet. Every training image is either permissively licensed (public domain or Creative Commons) or generated in-house. Positives are drawn from public-domain fine art and museum open-access collections (classical nudes in painting, sculpture, and photography), historic and documentary photography, and openly-licensed imagery, plus photorealistic images generated with generative image models. The backbone is Apache 2.0.

Clean, controlled provenance end to end is unusual for an NSFW classifier, where scraped datasets of unknown origin are the norm. It means no copyright or licensing exposure, and a model you can put in a commercial product with confidence.

## Evaluation

Held-out evaluation set (464 images, 75% SFW / 25% NSFW), scored on the single NSFW score at threshold 0.5 with the 8-crop pipeline.

| Metric | Moderator | NudeNet |
|---|---|---|
| Recall (catches NSFW) | **87.8%** | 82.6% |
| Specificity (SFW passed) | **93.7%** | 87.1% |
| False-block rate (SFW flagged) | **6.3%** | 12.9% |

Moderator beats NudeNet on both recall and precision, and flags about half as many SFW images.

## Limitations

- Adult-content classifier only. Subjects rendered as minors are out of scope by design; the training corpus excludes them and the model is not validated for that population.
- Accuracy is lower on difficult images (crowded scenes, extreme close-ups, low light, or low resolution) than on clear, well-lit ones.
- Anime/hentai and heavily-censored (mosaic) content are out of scope; the model is trained on photoreal.
- This is a content-moderation aid, not a legal determination. Use with human review for any decision the model is the only gate on.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for
most apps; a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.
