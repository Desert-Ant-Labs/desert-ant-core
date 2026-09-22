# Third-party notices

Components this repository's SDKs derive from, each under a license permitting
commercial use and derivative works.

Notices are per model, because the provenance is per model. A model's own notices
also ship on its Hugging Face card, which is the fuller version; this file is what
travels with the source.

---

## Redact

### Model
- **Multilingual-MiniLM-L12-H384** - Microsoft - **MIT**. Base encoder (truncated
  to 6 layers, EU-script vocab, fine-tuned for PII tagging).
- **GLiNER-PII** - NVIDIA - **NVIDIA Open Model License** (commercial + derivatives
  permitted; NVIDIA claims no ownership of outputs). Used to label training data.
  *Licensed by NVIDIA Corporation under the NVIDIA Open Model License.*
- **DeepSeek-V3.2-Exp** - DeepSeek - **MIT**. Used to generate synthetic training text.

### Training data (not redistributed here)
- `ai4privacy/pii-masking-openpii-1.5m` - **CC-BY-4.0**. Copyright © Ai Suisse SA.
  Attribution: **"Ai4Privacy / Ai Suisse SA"**.
- `gretelai/gretel-pii-masking-en-v1`, `gretelai/synthetic_pii_finance_multilingual` - **Apache-2.0**.
- `E3-JSI/synthetic-multi-pii-ner-v1` - **MIT**.
- `allenai/c4`, `HuggingFaceFW/fineweb-2` - **ODC-BY** (raw text for distillation).
- Synthetic values generated with **Faker** (MIT).

No non-commercial or unlicensed data is used.

---

## Align

On Apple, Align links only system frameworks (Core ML, AVFoundation, Speech, and Accelerate
through the shared AudioDSP module). On Linux and Windows it runs the LiteRT export through
LiteRT (Google, Apache-2.0), the package's `CLiteRt` dependency. Training-time data sources
and reference systems (LibriSpeech, AMI Meeting Corpus, FLEURS, Qwen3-ForcedAligner,
wav2vec 2.0, OWSM-CTC, the proposal engines) are attributed in the model repo's
`THIRD_PARTY_NOTICES.md` at
https://huggingface.co/desert-ant-labs/align/blob/main/THIRD_PARTY_NOTICES.md. The compiled
Align weights, calibration policy and Swift implementation are distributed under
[`LICENSE.md`](LICENSE.md).

---

## Emo, Clear

Not yet recorded here. Their notices live on their Hugging Face model cards; move
them in when each model's provenance is confirmed by whoever trained it.

---

## Tongue

Trained from scratch; derives from no third-party model. The training and
evaluation corpora below are licensed by their respective projects, and those
licenses apply to that data. Every source used for training is CC0, CC BY, or a
permissive software license; share-alike and non-commercial sources are excluded
by policy, and the corpus build enforces the exclusion and records a provenance
manifest of every file kept and dropped.

### Training data
- **Tatoeba** sentence and link exports - [tatoeba.org](https://tatoeba.org) -
  **CC BY 2.0 FR**, © Tatoeba contributors. The primary corpus.
- **Common Voice** sentence collections -
  [common-voice/common-voice](https://github.com/common-voice/common-voice)
  (`server/data`) - **CC0 1.0**. Files derived from Wikipedia or Europarl are
  excluded (share-alike upstreams).
- **Wikidata Lexemes** - [wikidata.org](https://www.wikidata.org) lexeme dumps -
  **CC0 1.0**.
- **Hunspell dictionaries** -
  [wooorm/dictionaries](https://github.com/wooorm/dictionaries) - per-dictionary
  permissive terms (MIT / BSD / Apache-2.0).
- **Universal Dependencies treebanks** -
  [universaldependencies.org](https://universaldependencies.org) - **CC BY 4.0**,
  verified per treebank; share-alike and non-commercial treebanks excluded.

### Evaluation only, never used for training
- **FLORES-200** - NLLB Team et al. - CC BY-SA 4.0 - held out.
- **WiLI-2018** - ODC-BY 1.0 - held out.
- **eld benchmark** -
  [nitotm/efficient-language-detector](https://github.com/nitotm/efficient-language-detector)
  - Apache-2.0 - held out. Leipzig / Wortschatz corpora are excluded from
  training in every form, because another detector's published test set is drawn
  from that collection.

---

## Android platform libraries

Android regex uses `java.util.regex.Pattern` and JSON parsing uses the Kotlin
host's native JSON, both through the JNI host. Android NFKC normalization uses
the platform `libicu.so` exposed by the NDK (API 31+), so no regex, JSON, or
Unicode normalization library is vendored or hand-rolled.

---

## Optional Swift package dependencies

Neither is in a default build: each sits behind a package trait, so a consumer
that does not ask for it never resolves or links it.

- **swift-xet** - Hugging Face - **Apache-2.0**. Xet-protocol model downloads on
  Apple platforms, behind the `Xet` trait. Pulls swift-nio, async-http-client and
  swift-nio-transport-services (Apple, **Apache-2.0**).
- **mlx-swift-lm** - Apple - **MIT**, and **swift-transformers** - Hugging Face -
  **Apache-2.0**. MLX generation for Title, behind the `MLX` trait.
