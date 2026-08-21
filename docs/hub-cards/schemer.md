---
license: other
license_name: desert-ant-labs-source-available-1.0
license_link: https://license.desertant.com/1.0
language:
- multilingual
- en
- de
- es
- fr
- it
- nl
- da
- 'no'
- sv
- pl
- pt
- ja
- zh
tags:
- text
- structured-output
- schema
- json
- extraction
- multilingual
- on-device
- core-ml
- onnx
pipeline_tag: other
---

# Schemer, on-device text to structured JSON

Schemer is a **schema-native extraction model**: it takes free text and a
developer-supplied schema, and returns a JSON object that matches the
schema. The schema is the model's input, not a prompt suggestion, and every
field is decoded by a head built for its type. It does not generate text.

- **211M parameters**: 218 MB int8 (verified lossless) or 111 MB int4
- **13 languages**, 0.075 per-language accuracy spread
- **Nested schemas**: arrays of objects extract via deterministic
  segment-and-recurse in the harness (0.99 on the internal nested eval)
- **Documents up to ~1,100 tokens** (roughly 3 pages); short inputs run a
  fast 256-token path
- **Offline**, ~200 MB RAM; 8.7 ms per encoder pass on an Apple Neural
  Engine

Three guarantees no generative extractor offers:

1. **Typed by construction.** Labels are always one of your declared
   choices, numbers arrive clamped to your range, datetimes are ISO 8601,
   and relative expressions ("tomorrow at 3pm", "i morgen kl 15",
   misspellings included) resolve against device time.
2. **Absence detection.** Fields the text does not state come back null.
   Schemer scores 0.91 on this; every LLM and span extractor we benched,
   at any size, scores between 0.18 and 0.43.
3. **Verbatim with offsets.** Extracted strings are substrings of the
   input; the SDK surfaces character offsets, so hallucination auditing is
   a substring check.

> **Private pre-release.** Weights are staged here ahead of the SDK
> release.

## Try it

- **iOS / macOS:** Swift SDK coming soon. The int4
  Core ML encoders in `coreml/` are ANE-validated (8.1 ms/forward at the
  256-token shape) and eval-confirmed on-device.
- **Android / web:** ONNX graphs are staged in `onnx/` (int4 web encoder +
  fp32 support graphs, quality measured through the actual graphs); the JS
  harness port ships with the SDK.
- The deterministic harness (relative dates, duration units, format gates,
  string trims, anchor injection) ships as data in `harness/*.json`; every
  SDK port must pass the bundled conformance fixtures bit-for-bit.

## Files

| File | Format | Size | Use |
|---|---|---:|---|
| `model-int8.pt` | int8 per-row | 218 MB | start here; full quality (0.800 overall) |
| `model-int4-awq.pt` | int4 AWQ | 111 MB | when download or RAM is tight (0.793 overall) |
| `model-fp32.pt` | fp32 | 850 MB | converting to other formats; not for deployment |
| `onnx/encoder_web4e4.onnx` | int4 ONNX | 111 MB | run in the browser or on Android |
| `onnx/*.onnx` | fp32 ONNX | 80 MB | decoding graphs; always ship with the encoder |
| `coreml/*.mlpackage.zip` | int4 Core ML | 84 MB each | run on iOS / macOS; 256 + 1216 token shapes, ANE-resident, eval-confirmed on-device |
| `tokenizer/`, `keep_ids.json` | | 11 MB | required by every runtime |
| `harness/*.json` | | <1 MB | post-processing and nested-recursion rules every SDK port must implement |
| `manifest.json` | | | verify downloads; measured quality per artifact |

## Use

The schema is plain JSON (paste an OpenAI/Gemini `responseSchema` and it
works). One call per document:

```json
{
  "title":        {"type": "string",  "describe": "the task title", "max_chars": 60},
  "guest":        {"type": "string",  "describe": "person the meeting is with", "nullable": true},
  "start":        {"type": "datetime","describe": "start time", "nullable": true},
  "duration_min": {"type": "number",  "describe": "duration in minutes", "min": 0, "max": 480, "nullable": true},
  "is_recurring": {"type": "boolean", "describe": "is this a recurring task"}
}
```

Input `"Meeting with Sarah tomorow at 3pm for an hour to review the Q3
deck. Recurring weekly."` returns (with device time 2026-07-05):

```json
{"title": "review the Q3 deck", "guest": "Sarah",
 "start": "2026-07-06T15:00", "duration_min": 60, "is_recurring": true}
```

Note the typo tolerance, the relative-date resolution, the unit conversion
("an hour" to 60), and the factoring: the title is the purpose of the
meeting, the person lands in `guest`, and the temporal clutter lands in
the temporal fields.

## Model

- **Encoder:** pruned mmBERT-base (22 layers, 103k-token vocabulary kept of
  256k), jointly encoding `[schema summary ||| document]`. Two compiled
  input shapes: 256 tokens (records) and 1216 tokens (documents). The
  1216-token shape is the input limit: schema summary + document together;
  longer inputs are truncated, so budget roughly 1,100 tokens of document.
- **Reader:** one shared cross-attention reader over encoder states.
- **Heads:** thin per-type decoders: label entailment, 3-way boolean
  (absent/false/true), BIO span tagging for strings and arrays with trained
  presence gates, datetime and number component decoders.
- **Harness:** deterministic post-processing (locale number parsing, ISO
  composition, 13-language relative-date lexicons, format gates). Shipped
  as data plus a reference implementation; ports are conformance-tested.

## Evaluation

9,021 held-out records across seven usage slices, 13 languages, schemas
the model never saw, one order-insensitive, absence-aware scorer for
every model. The overall score weights the slices by product usage:
short records 0.30, long documents 0.15, long documents with same-type
distractors 0.15, reviews and registers 0.15, calendar 0.10, factored
domains 0.10, nested schemas 0.05. Every model ran in its documented
configuration (tool calling for FunctionGemma, template prompts for
NuExtract-2.0, JSON chat for the instruct models, in-process span
extraction for GLiNER2); sizes are measured bytes of the artifact
benched.

| Model | Overall | Absence (boolean) | Params | On disk |
|---|---:|---:|---|---|
| Gemma 4 26B A4B (int4 AWQ) | 0.834 | 0.428 | 26.6B | 17.2 GB |
| Claude Haiku 4.5 (API) | 0.816 | 0.431 | n/a | API only |
| Qwen 3.5 9B | 0.812 | 0.434 | 9.1B | 9.1 GB |
| **Schemer** | **0.800** | **0.911** | 211M | 218 MB int8 |
| **Schemer (int4)** | **0.793** | 0.908 | 211M | 111 MB int4 |
| Ministral 3 8B | 0.790 | 0.430 | 8.0B | 17.8 GB |
| Gemma 4 E2B (official int4 QAT) | 0.780 | 0.427 | 5.1B | 8.3 GB |
| Qwen 3.5 0.8B | 0.651 | 0.351 | 0.87B | 1.75 GB |
| NuExtract-2.0-2B | 0.643 | 0.393 | 2.2B | 4.4 GB |
| GLiNER2-multi | 0.585 | 0.374 | 307M | 309 MB int8* |
| GLiNER2-base | 0.524 | 0.368 | 205M | 834 MB |
| NuExtract-tiny-v1.5 | 0.334 | 0.222 | 0.5B | 954 MB |
| FunctionGemma 270M (tool calling) | 0.288 | 0.181 | 0.27B | 0.54 GB |

*GLiNER2-multi int8 size verified by us with the same
quantize-and-rebench methodology as our own int8 claim (accuracy held
within 0.004 of fp32).

### Per slice

| Model | Short | Long doc | Long + distractors | Register | Calendar | Factored | Nested |
|---|---:|---:|---:|---:|---:|---:|---:|
| Gemma 4 26B A4B | **0.844** | **0.844** | 0.693 | 0.815 | 0.829 | 0.954 | **1.000** |
| Claude Haiku 4.5 | 0.838 | 0.759 | **0.762** | **0.831** | 0.802 | 0.817 | **1.000** |
| Qwen 3.5 9B | 0.828 | 0.807 | 0.717 | 0.791 | 0.774 | 0.891 | **1.000** |
| **Schemer** | 0.759 | 0.708 | 0.685 | 0.829 | **0.946** | 0.946 | 0.988 |
| **Schemer (int4)** | 0.754 | 0.689 | 0.671 | 0.820 | 0.943 | **0.967** | 0.985 |
| Ministral 3 8B | 0.818 | 0.811 | 0.711 | 0.720 | 0.796 | 0.790 | 0.998 |
| Gemma 4 E2B | 0.809 | 0.785 | 0.705 | 0.773 | 0.719 | 0.759 | **1.000** |
| Qwen 3.5 0.8B | 0.721 | 0.635 | 0.560 | 0.581 | 0.529 | 0.689 | 0.936 |
| NuExtract-2.0-2B | 0.763 | 0.704 | 0.542 | 0.648 | 0.496 | 0.805 | 0.000† |
| GLiNER2-multi | 0.683 | 0.650 | 0.388 | 0.662 | 0.468 | 0.783 | 0.000† |
| GLiNER2-base | 0.619 | 0.587 | 0.371 | 0.612 | 0.362 | 0.668 | 0.000† |
| NuExtract-tiny-v1.5 | 0.406 | 0.277 | 0.248 | 0.280 | 0.275 | 0.417 | 0.439 |
| FunctionGemma 270M | 0.339 | 0.254 | 0.232 | 0.274 | 0.299 | 0.421 | 0.000† |

†The NuExtract-2.0, GLiNER2, and FunctionGemma interfaces cannot express
arrays of objects; their nested cells score the resulting empty output.
This is an interface limit, not an extraction failure.

### Per field type

Bold marks the best score in each row. Schemer's architecture shows plainly: it owns the typed/absence rows and trails larger extraction LLMs on free-text rows.

| Type | Schemer | Schemer (int4) | NuExtract-2.0-2B (2.2B) | Qwen 3.5 0.8B |
|---|---:|---:|---:|---:|
| boolean | **0.911** | 0.908 | 0.393 | 0.351 |
| datetime | **0.769** | 0.752 | 0.641 | 0.652 |
| array | **0.766** | 0.750 | 0.731 | 0.686 |
| number | **0.750** | 0.743 | 0.670 | 0.679 |
| string | 0.648 | 0.637 | **0.774** | 0.716 |
| label | 0.629 | 0.609 | **0.636** | 0.616 |

### Per language

Measured on the three slices that cover all 13 languages with identical
composition (short records, long documents, long documents with
distractors; ~600 records per language).

| Language | Schemer | Qwen 3.5 0.8B | GLiNER2-multi |
|---|---:|---:|---:|
| French | **0.745** | 0.649 | 0.606 |
| Spanish | **0.734** | 0.662 | 0.610 |
| Italian | **0.731** | 0.653 | 0.603 |
| Portuguese | **0.729** | 0.640 | 0.601 |
| German | **0.728** | 0.635 | 0.591 |
| Dutch | **0.724** | 0.621 | 0.600 |
| Danish | **0.723** | 0.618 | 0.594 |
| English | **0.717** | 0.706 | 0.632 |
| Norwegian | **0.717** | 0.620 | 0.600 |
| Swedish | **0.715** | 0.633 | 0.624 |
| Japanese | **0.707** | 0.614 | 0.384 |
| Chinese | **0.683** | 0.640 | 0.408 |
| Polish | **0.670** | 0.609 | 0.597 |

Schemer scores 0.800 overall; every model above it runs 9.1B to 26.6B
parameters or an API. NuExtract-2.0-2B, the closest task-specific
extractor, scores 0.643 at ten times the parameters. Schemer wins all
13 languages against both the strongest sub-1B LLM and GLiNER2-multi,
posts the top calendar score of any model at any size (0.946 next to
the 26B's 0.829), and is the only model with reliable absence detection
(0.911 next to a 0.18 to 0.43 field). Long documents: 0.708 at ~1,100
tokens; 0.685 when the document contains same-type distractor records.

## Limitations

- **Nested schemas** extract via the harness (segment and recurse), not
  the model itself: quality on messy real-world prose is not yet benched
  externally; the 0.99 figure is our internal template-based eval.
- **Extractive strings only:** Schemer will not compose or rewrite text;
  abstractive titles from messy prose trail extraction LLMs (string
  0.641 vs 0.774 for NuExtract-2.0-2B and ~0.86 for the 8B+ class). It
  does factor titles extractively (purpose clause, people and times split
  into their fields), but the title is always a substring of the input.
- **Judgment labels** requiring world knowledge (severity triage) trail
  the 8B+ class (0.629 vs ~0.82).
- **Not a NER model:** it fills your fields; it does not enumerate every
  entity mention (CrossNER span-F1 0.24 vs GLiNER2's 0.59).
- English is the weakest of the 13 languages relative to competitors.

## Citation

```bibtex
@software{schemer_2026,
  title  = {Schemer: on-device text to structured JSON},
  author = {Desert Ant Labs},
  year   = {2026},
  url    = {https://huggingface.co/desert-ant-labs/schemer}
}
```

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for
most apps; a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.
