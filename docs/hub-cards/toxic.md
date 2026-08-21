---
license: other
license_name: desert-ant-labs-source-available-1.0
license_link: https://license.desertant.com/1.0
language:
- en
- de
- fr
- nl
- pt
- es
- it
- pl
- da
- sv
- fi
- hu
- cs
- sk
- sl
- hr
- bg
- el
- ro
- lt
- lv
- et
- ga
tags:
- hate-speech
- hate-speech-detection
- toxicity-classification
- content-moderation
- offensive-language
- text-classification
- on-device
- edge-ai
- mobile
- ios
- android
- browser
- offline
- litert
- tflite
- core-ml
- coreml
- onnx
- multilingual
pipeline_tag: text-classification
---

# toxic: on-device multilingual hate-speech and abuse triage

`toxic` v0.1.0: a multilingual toxicity classifier for on-device hate
speech detection and content moderation triage. Three content heads
(`HATEFUL`, `ABUSIVE`, `THREAT`) plus protected-group target heads, across
23 languages; each head is named for what its training labels measure and
benchmarked individually below. Inference is 100% on-device: no text
leaves the device to be scored.

**0.847 macro-F1 on real Multilingual HateCheck across the seven EU
languages** (de, fr, nl, pt, es, it, pl), measured on the shipped weights;
three independent training runs of this recipe average **0.834**.

**Out-of-domain corroboration, real in-the-wild corpora (binary
toxic-vs-clean):** textdetox **0.724** macro-F1 (5 languages) and
offenseval2020 **0.658** (3 languages), shipped weights, method stated
with the tables below. These two sets share no construction lineage with
our development benchmarks, which is exactly why they are here.

**Provenance is load-bearing in this card and never blurred.** Eight of the
23 languages (English plus the 7-EU set) are scored on real Multilingual
HateCheck, the published, peer-reviewed benchmark. The other 15 are scored
on translate-and-audit synthetic evaluation sets built for this project;
those numbers are development-benchmark estimates, not MHC-comparable, and
are never averaged into the 7-EU headline. Per-language tables for both
tiers below are re-measured on the exact shipped bytes.

**Looking for English only?** See
[`toxic-en`](https://huggingface.co/desert-ant-labs/toxic-en), the English
specialist. Same idea as Whisper's `.en` models: this multilingual model
covers English too, but a model trained only on English does the job better
for English-first apps. The English specialist scores
0.855 on English real HateCheck against this model's 0.852; its card carries
the per-artifact numbers.

**Triage, not verdict.** Outputs are escalation signals for human review or
a heavier local tier, not autonomous removal decisions. The failure modes
below are published on purpose: read them before wiring the model into any
enforcement path.

## Try it

[`desert-ant-labs/toxic-demo`](https://huggingface.co/spaces/desert-ant-labs/toxic-demo),
a Hugging Face Space. Type or paste text and watch the scores live in the
browser; nothing you type leaves the page.

## Taxonomy: three heads, each named for its supervision

Three content heads and ten target heads share one encoder, exposed as two
multi-label output layers (content and target). Text can fire several heads
at once; thresholds apply per head.

- **`HATEFUL`**: public incitement to violence or hatred against a protected
  group. Scoped to the EU notion of illegal hate speech (Framework Decision
  2008/913/JHA).
- **`ABUSIVE`**: abusive and insulting language, severity-ordered. Trained
  on human severity annotations (civil_comments `insult` / `identity_attack`
  crowd votes and per-corpus equivalents). It is a superset of `HATEFUL`: a
  group-identity attack is also abusive language. It is **not** a
  directedness signal: it does not tell you the abuse is aimed at the
  reader, at a named person, or at anybody in particular, and integrations
  must not infer that from the name or from a high score.
- **`THREAT`**: threat of violence toward a person or group.
- **Target heads (10):** the 2008/913/JHA protected grounds `RACE`,
  `COLOUR`, `RELIGION`, `DESCENT`, `NATIONAL_ETHNIC_ORIGIN`, plus the
  extended grounds `SEXUAL_ORIENTATION`, `GENDER`, `DISABILITY`, `AGE`,
  `OTHER`. Only meaningful when `HATEFUL` fires; used for per-ground
  fairness reporting.

The `disabled_heads` mechanism in the meta (currently empty) is the valve
for shipping any future failed gate safely: a head named there is pinned to
an unreachable threshold on every platform.

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `toxic.tflite` | LiteRT / TFLite (int4 blockwise-32) | 90.6 MB | Android and Linux, native LiteRT kernels |
| `toxic.onnx` | ONNX (int4 + int4 embedding) | 100.2 MB | Browser artifact for ONNX Runtime Web |
| `toxic.mlmodelc` | Core ML (4-bit palettized) | 80.2 MB | iOS / macOS, CPU+Neural Engine |
| `toxic.pt` | PyTorch state dict (fp32) | 638.5 MB | Torch reference weights (~159.6M params, trimmed vocab) |
| `config.json` | JSON | tiny | Encoder + head config (base, labels, `max_len`, vocab size) |
| `tokenizer.json`, `tokenizer_config.json` | JSON | 3.7 MB | Trimmed (95,552-piece) SentencePiece-Unigram tokenizer (XLM-R lineage) |
| `toxic_tokenizer.bin` | binary | 1.3 MB | The same tokenizer, precompiled binary form |
| `labels.json` | JSON | tiny | `id2label` / `label2id` for both heads |
| `toxic_meta.json` | JSON | tiny | Schema, labels, per-head + per-language thresholds, `disabled_heads` |

Artifact sizes and per-artifact quality were re-measured on the exact
shipped bytes at export; nothing in this table is extrapolated from a
training checkpoint.

## Measured quality

### 7-EU real Multilingual HateCheck (the headline harness)

| model | 7-EU macro-F1 |
| --- | --: |
| **Shipped weights (torch reference)** | **0.8470** |
| Training-run mean, 3 seeds (0.8219 / 0.8323 / 0.8470) | 0.8337 |

The shipped weights are the strongest of three full training runs; the mean
is what a retrain of this recipe should reproduce.

### Per language, real Multilingual HateCheck, on the shipped bytes

| language | torch reference | ONNX int4 (browser) | TFLite int4 (Android) |
| --- | --: | --: | --: |
| Dutch (nl) | 0.834 | 0.825 | 0.816 |
| German (de) | 0.865 | 0.861 | 0.850 |
| French (fr) | 0.861 | 0.848 | 0.828 |
| Italian (it) | 0.839 | 0.823 | 0.830 |
| Spanish (es) | 0.844 | 0.846 | 0.825 |
| Polish (pl) | 0.837 | 0.833 | 0.828 |
| Portuguese (pt) | 0.850 | 0.834 | 0.836 |
| English (en) | 0.852 | 0.839 | 0.857 |
| **7-EU mean** | **0.8470** | **0.8386** | **0.8304** |

Quantization costs, measured: ONNX int4 -0.8 points against the torch
reference on the 7-EU mean, TFLite int4 -1.7, Core ML int4 -1.5 (7-EU
0.8320, English 0.796, measured through the Core ML runtime on Apple
silicon at the release's pinned CPU+Neural Engine configuration). English
costs Core ML more than the other lanes; English-first iOS apps should
prefer the English specialist. Threshold 0.40 throughout: that is the
shipped default for `HATEFUL`, the only head this hate-only benchmark
exercises (`ABUSIVE` and `THREAT` ship at 0.50).

### Against runnable local baselines, same harness, same rows

Every system below was scored by this project's own HateCheck harness on
identical rows, so the comparison measures the models, not the plumbing.
Our operating point is the shipped 0.40 default. Each competitor's
operating point, stated in full:

- **Llama-Guard-3-1B** emits a binary safe/unsafe verdict; there is
  nothing to tune.
- **Qwen3Guard-Gen-0.6B** emits a third "controversial" verdict on 19 to
  34% of these rows per language. The table counts only a strict "unsafe"
  as a hate verdict, the mapping that favors it: counting "controversial"
  as hateful drops its 7-EU mean from 0.652 to 0.563 and English from
  0.770 to 0.600, measured.
- **Detoxify multilingual** is scored at its published 0.5 default. A
  per-language best-threshold search lifts its 7-EU mean only to 0.498,
  so the gap is not an operating-point artifact.
- **Shieldstral-1.0-3B** (Mistral, August 2026) is policy-adaptive: it
  takes a written policy at inference time and returns a calibrated
  yes/no score in one forward pass. It was given this benchmark's own
  target definition (hate toward protected groups, with counter-speech,
  reclaimed slurs, and abuse at non-protected targets stated as non-hate)
  and scored at its calibrated 0.5 default; a per-language threshold
  sweep lifts its 7-EU mean only to 0.791. Of four policy wordings
  tested, including Mistral's own strict-moderator card example, this one
  scores highest for Shieldstral (the alternatives cost it 2.0 to 3.9
  points on en/de) and is the only one whose best threshold is the
  calibrated default, so the row shows the model at its measured best.
  Its one published artifact is bf16 (7.7 GB, a 16 GB-GPU model):
  runnable locally, not phone-class.

| system | params | 7-EU macro-F1 | English |
| --- | --- | --: | --: |
| **toxic v0.1.0 (shipped weights, torch)** | 159.6M | **0.847** | 0.852 |
| Shieldstral-1.0-3B | 3B | 0.786 | 0.820 |
| Qwen3Guard-Gen-0.6B | 0.6B | 0.652 | 0.770 |
| Llama-Guard-3-1B | 1B | 0.649 | 0.814 |
| Llama-Guard-3-1B (int4) | 1B | 0.633 | 0.794 |
| Qwen3Guard-Gen-0.6B (int4) | 0.6B | 0.622 | 0.750 |
| Detoxify multilingual | 278M | 0.487 | 0.642 |

The [`toxic-en`](https://huggingface.co/desert-ant-labs/toxic-en) English
specialist scores 0.855 on the same English set at 31.9M parameters.

For literature context (not measured with this harness): fine-tuned
task-specific English models reach 0.85 to 0.90 macro-F1 on English
HateCheck, and Röttger et al. (2021) report commercial cloud APIs around
0.60. Our English scores (0.852 multilingual, 0.855 specialist) sit inside
the published fine-tuned band, on device.

Prompted general-purpose local LLMs were measured on the English set too.
Gemma 4 12B reaches 0.958 and beats every dedicated classifier including
ours, at roughly 75x this model's parameters. The only other prompted
model to match us is Granite 4.0 tiny (7B) at 0.856, some 220x the
parameters of `toxic-en`. Every prompted model under 4B scored below both
of our models. Cloud APIs are deliberately not on this card: everything
compared here runs locally, under your control, and the bolded row runs
on a phone.

### Out of domain, real corpora (binary toxic-vs-clean)

Shipped torch reference. Our prediction is the union of the three content
heads (max probability at threshold 0.40, exactly the release's flag-if-any
rule); Detoxify multilingual scores the same rows at its conventional
0.50. Neither model is threshold-tuned on the benchmark. Means are
unweighted over the listed languages: the intersection of each benchmark's
languages with our 23.

| benchmark | languages | toxic macro-F1 | toxic ROC-AUC | Detoxify macro-F1 | Detoxify ROC-AUC |
| --- | --- | --: | --: | --: | --: |
| textdetox | en, de, fr, es, it | 0.724 | 0.843 | 0.771 | 0.865 |
| offenseval2020 | en, da, el | 0.658 | 0.804 | 0.673 | 0.737 |

Read per language before deploying: Detoxify's wins concentrate in
English, its home construct and register (0.964 and 0.925 macro-F1 there);
on German textdetox it collapses to 0.353 where this model holds 0.765.
These corpora label broad offensiveness rather than this card's taxonomy,
so this section measures construct transfer, not the heads on their own
definitions.

### Per head, held-out civil_comments, vs Detoxify-unbiased

Same data, same split, paired confidence intervals; ROC-AUC because the two
models calibrate differently. Detoxify-unbiased is the incumbent
same-architecture-class classifier, scored on its home dataset. Measured on
the shipped weights, 97,320 held-out rows.

| head | toxic v0.1.0 (shipped weights) | Detoxify-unbiased | delta 95% CI |
| --- | --: | --: | --- |
| `HATEFUL` | 0.9801 | 0.9887 | [-0.011, -0.006] |
| `ABUSIVE` (its supervision) | 0.9508 | 0.9778 | [-0.029, -0.025] |
| `THREAT` | 0.9761 | 0.9892 | [-0.020, -0.005] |

Read this honestly: these are close losses on Detoxify's home dataset. We
carry 23 languages and 3 heads on one trunk; Detoxify-unbiased is an
English-only model evaluated where it trained. The next table is what the
multilingual trunk buys.

### German, germeval2018 held-out 10% (ROC-AUC)

We trained on the other 90% of germeval2018 and say so; Detoxify
multilingual did not train on it. Shipped weights, 420 held-out rows,
paired bootstrap CIs on the AUC difference.

| head | toxic v0.1.0 (shipped weights) | Detoxify multilingual | delta 95% CI |
| --- | --: | --: | --- |
| `HATEFUL` | 0.8523 | 0.5912 | [+0.196, +0.331] |
| `ABUSIVE` | 0.8777 | 0.4984 | [+0.292, +0.466] |

### HateXplain: human labels, out of domain, length-unconfounded

HateXplain was never trained on, its labels are human, and its hate and
non-hate classes have matched length distributions, so a length shortcut
scores nothing here.

Shipped weights, 20,148 posts, three human annotators each.

| contrast | subset | `HATEFUL` ROC-AUC |
| --- | --- | --: |
| hate vs normal | all posts | 0.8238 |
| hate vs normal | unanimous annotators | 0.8823 |
| hate vs offensive | all posts | 0.6820 |
| hate vs offensive | unanimous annotators | 0.7247 |

The hate-vs-offensive numbers are the honest ones to sit with: separating hate from
merely offensive text is much harder than separating hate from normal text,
for this model and for the field. Do not build a product feature that
requires the hate/offensive boundary to be sharp.

### The 15 synthetic-eval languages

The 15 languages beyond the real-MHC set are scored on translate-and-audit
synthetic sets built for this project (`data/eval/mhc_v2/`). Those numbers
are provenance-tagged development estimates and are never co-averaged with
real-MHC numbers, in this card or anywhere else. 444 rows across these sets
(0.8%) could not be fully verified by the translation audit and are counted
in these numbers (the eval harness has no per-row exclusion path); Danish,
Latvian and Swedish carry the largest shares. Torch reference, threshold
0.40:

| language | macro-F1 (synthetic set, torch) |
| --- | --: |
| Danish (da) | 0.866 |
| Swedish (sv) | 0.863 |
| Finnish (fi) | 0.747 |
| Hungarian (hu) | 0.746 |
| Czech (cs) | 0.780 |
| Slovak (sk) | 0.791 |
| Slovenian (sl) | 0.760 |
| Croatian (hr) | 0.795 |
| Bulgarian (bg) | 0.829 |
| Greek (el) | 0.788 |
| Romanian (ro) | 0.833 |
| Lithuanian (lt) | 0.729 |
| Latvian (lv) | 0.744 |
| Estonian (et) | 0.778 |
| Irish (ga) | 0.670 |
| mean (never co-averaged with real MHC) | 0.7812 |

The same baselines were run on these synthetic sets, same rows for every
system. Read this one asymmetrically: we trained toward these 15 languages
and the baselines did not, so it demonstrates coverage they do not have
rather than a like-for-like quality win.

| system | params | synth-15 mean macro-F1 |
| --- | --- | --: |
| **toxic v0.1.0 (shipped weights, torch)** | 159.6M | **0.781** |
| Shieldstral-1.0-3B | 3B | 0.684 |
| Llama-Guard-3-1B | 1B | 0.446 |
| Qwen3Guard-Gen-0.6B | 0.6B | 0.439 |
| Detoxify multilingual | 278M | 0.291 |

Shieldstral is the only baseline that holds a real score here, and it
loses on the languages with the least text behind them: Irish 0.537 and
Estonian 0.529 against this model's 0.670 and 0.778, consistent with the
low-resource weakness Mistral reports in the [Shieldstral
paper](https://arxiv.org/abs/2607.25857) (Table 8: their own
prompt-classification scores fall away on Indonesian and Arabic).
Every row here is scored on the repaired sets: the three older baselines
were re-measured after 4 unusable Bulgarian rows were dropped, and not one
of their numbers moved at this precision.

## How these numbers were made

The evaluation discipline is the product as much as the weights are:

- **Every artifact-bound number is re-measured on the exact shipped bytes**,
  not extrapolated from the training checkpoint.
- **Provenance is tracked per language and never blurred.** Real
  Multilingual HateCheck is the only source for the headline; the 15
  synthetic languages are reported separately and labelled.
- **Benchmarks are eval-only, with one honest qualification.** No HateCheck
  row appears in training, in any language: that is enforced mechanically by
  a hash-intersection check over every generated file. But HateCheck is a
  *development* benchmark for this project at the construct level: the
  template generator mirrors its functional cell names and the clean-side
  generator targets its non-hate cells by name. So "no verbatim overlap" is
  what we verify, and "held out" is not what we claim. The out-of-domain
  numbers (textdetox, offenseval2020, HateXplain) are the ones to weigh if
  you want figures untouched by that dependency.
- **Every number names its denominator**, and comparisons run both models
  through the identical harness.

## Failure modes (read before deploying)

Measured on the shipped bytes (ONNX artifact): non-hate false-positive
rates at threshold 0.40 run 0.26 to 0.30 across the 7-EU languages and
0.12 on English. The construct-level failure modes that survive any
retrain of this architecture:

**1. It sometimes flags people quoting or condemning hate.** Counter-speech
and news reporting repeat the hateful words they argue against, and the
model reacts to the words. Route flags to human review; never auto-remove
on this signal alone.

**2. Positive or neutral mentions of identity groups can trip it,
especially outside English.** Treat short identity-statement texts as
low-confidence.

**3. `ABUSIVE` is a severity signal, not a targeting signal.** It orders
text by how abusive the wording is. It will score some undirected profanity
and some crude-but-aimless text; it does not know who, if anyone, is being
addressed. If your policy distinguishes "attacks a person" from "swears a
lot", this head alone cannot enforce that policy. The reason is measured,
not stylistic: a directedness construct could not be validated at available
label quality, so the head claims severity and nothing else.

**4. Hate phrased as a question or an implication is harder than direct
insults**, for this model and the field. Do not promise users that subtle
hate is always caught.

**5. The hate/offensive boundary is soft.** See the HateXplain table: 0.7247
hate-vs-offensive against 0.8823 hate-vs-normal on the unanimous subset.
Thresholds move along that boundary; they do not sharpen it.

**6. Not yet measured: latency.** No latency number appears on this card
because none has been measured on the shipped artifacts. Latency is
published once measured, never assumed. The quantization deltas above
already follow that rule.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0).
Free below 100,000 monthly active devices per platform, per model; a
commercial license is required beyond that. Full terms at the link.
Licensing: <licensing@desertant.com>.

Built exclusively from commercially clean components (CC0 / CC-BY / MIT /
Apache-2.0 training data, MIT base encoder). Attributions, dataset citations
and generator credits are in `THIRD_PARTY_NOTICES.md`.

## Citation

```bibtex
@software{toxic_2026,
  title  = {toxic: on-device multilingual hate-speech and abuse triage},
  author = {Desert Ant Labs},
  year   = {2026},
  url    = {https://huggingface.co/desert-ant-labs/toxic},
}
```

---

© 2026 Desert Ant Labs · <https://desertant.com>
