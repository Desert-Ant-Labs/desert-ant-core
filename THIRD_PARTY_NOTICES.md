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

## Emo, Clear

Not yet recorded here. Their notices live on their Hugging Face model cards; move
them in when each model's provenance is confirmed by whoever trained it.

---

## Android platform libraries

Android regex uses `java.util.regex.Pattern` and JSON parsing uses the Kotlin
host's native JSON, both through the JNI host. Android NFKC normalization uses
the platform `libicu.so` exposed by the NDK (API 31+), so no regex, JSON, or
Unicode normalization library is vendored or hand-rolled.
