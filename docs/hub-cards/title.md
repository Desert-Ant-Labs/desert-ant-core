---
license: other
license_name: desert-ant-labs-source-available-1.0
license_link: https://license.desertant.com/1.0
language:
- multilingual
tags:
- text
- text-generation
- summarization
- on-device
- mlx
- multilingual
pipeline_tag: text-generation
---

# title

Writes a title and a one or two sentence description for a passage of text, on device.

Fine-tuned on transcript clips, but the task it learned is general: it takes prose and returns
a card for it. The register is deliberately plain, with no emoji, no hashtags and no clickbait,
and a description is meant to identify *this* passage rather than its topic.

## Files

An MLX model directory. Load the folder, not a single file.

| File | Contents |
|---|---|
| `model.safetensors` | 6-bit quantized weights |
| `model.safetensors.index.json` | shard index; present even for one shard, because the loader reads it |
| `config.json` | architecture and quantization config |
| `generation_config.json` | decode defaults |
| `tokenizer.json`, `tokenizer_config.json` | byte-level BPE with merges |
| `chat_template.jinja` | the chat template the fine-tune was trained against |

The chat template is not incidental. A different template is a different task to this model.

## The prompt

The model was fine-tuned against one specific instruction, and a paraphrase is a different
task to it. It lives in `Titles.prompt` in the SDK; use that wording. The reply is two labelled
lines:

```
TITLE: <3-8 words, no final punctuation>
DESC: <1-2 sentences>
```

Parse tolerantly. A card model that drifts off format should degrade to a usable title rather
than throw.

## Apple only

MLX runs on Apple silicon and nowhere else, so there is no Android, Linux or Windows artifact
here and no manifest promising one. A Core ML export exists in the training repository and is
kept as evidence rather than as a candidate: on short autoregressive decode the Neural Engine
is bandwidth-bound, and the Core ML arm lost on first token, throughput, load time and resident
memory.

## Status

Internal testing, and less settled than that phrase usually implies. This card carries no
quality figures: no independent review has been completed, and a known open issue is that the
model sometimes opens a description with a stock phrase its own instruction forbids. Treat the
output as needing a read before it reaches a user.

## Built on

- [`ibm-granite/granite-4.0-350m`](https://huggingface.co/ibm-granite/granite-4.0-350m) —
  the base model this is fine-tuned from.

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for most
apps; a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

---

© 2026 Desert Ant Labs · <https://desertant.com>
