---
license: other
license_name: desert-ant-labs-source-available-1.0
license_link: https://license.desertant.com/1.0
language:
- bg
- hr
- cs
- da
- nl
- en
- et
- fi
- fr
- de
- el
- hu
- ga
- it
- lv
- lt
- mt
- pl
- pt
- ro
- sk
- sl
- es
- sv
- nb
- nn
- is
tags:
- pii
- redaction
- token-classification
- on-device
- litert
- tflite
- core-ml
- multilingual
pipeline_tag: token-classification
---

# redact: on-device multilingual PII redaction

Detects and redacts personal data (names, addresses, emails, phone numbers,
cards, IBANs, national IDs and more) in text across **27 languages**
(see [Languages](#languages)). A BIOES token classifier plus a portable, dependency-free
deterministic layer for structured IDs. The deployable model is **~11.6 MB**
(4-bit Core ML on Apple) or **~24.5 MB** (int8 LiteRT `.tflite` on Android, Linux
and the web).

> `"Call Anna Kovács at anna@example.hu, IBAN GB29NWBK60161331926819"` →
> `"Call [GIVEN_NAME] [SURNAME] at [EMAIL], IBAN [BANK_ACCOUNT]"`

## Try it

All platforms ship from one repo: **[Desert-Ant-Labs/redact](https://github.com/Desert-Ant-Labs/redact)** (Swift, Kotlin, and JavaScript in a single codebase).

- **Live demo:** [desert-ant-labs/redact-demo](https://huggingface.co/spaces/desert-ant-labs/redact-demo): paste text and watch PII get highlighted or masked, fully in your browser.
- **iOS / macOS / tvOS / visionOS:** the Swift SDK (Swift Package Manager) with a built-in demo app. It bundles the compiled Core ML model below.
- **Android / JVM (Kotlin):** Maven Central `ai.desertant:redact` — LiteRT (`.tflite`), with the model downloaded on demand or bundled via `ai.desertant:redact-tflite-resources`.
- **Node / browser (JavaScript / TypeScript):** `npm i @desert-ant-labs/redact @litertjs/core` for browser builds, or just `npm i @desert-ant-labs/redact` for server-side Node. The npm package downloads the model from this repo on first use and caches it; browser inference uses [LiteRT.js](https://www.npmjs.com/package/@litertjs/core), and Node uses prebuilt native libraries. Pass `directory` (Node) or `modelBaseUrl` (browser) to self-host / run offline.

```swift
import Redact

let redact = Redact()
let r = try await redact.redaction(of: "Email Anna Kovács at anna@example.hu.")
r.redactedText   // "Email [GIVEN_NAME_1] [SURNAME_1] at [EMAIL_1]."
```

## Taxonomy (20 public labels, plus `ORG`)

`GIVEN_NAME`, `SURNAME`, `STREET_NAME`, `BUILDING_NUMBER`, `SECONDARY_ADDRESS`,
`CITY`, `STATE`, `ZIP_CODE`, `EMAIL`, `PHONE`, `CREDIT_CARD`, `BANK_ACCOUNT`,
`ROUTING_NUMBER`, `IP_ADDRESS`, `URL`, `GOVERNMENT_ID`, `PASSPORT`,
`DRIVERS_LICENSE`, `TAX_ID`, `SSN`.

`ORG` (organisation / company name) is detected but **not redacted by default**:
a company is not a natural person. It exists so that `Silverfin`, `Odoo` or
`Visma Nova` are recognised as organisations instead of being mislabelled as a
`SURNAME`. Opt in by passing it explicitly in the SDK's `labels` option.

The deterministic layer additionally emits `IMEI` (device identifier), a
deterministic-only label outside the neural head.

## How it compares

Every system below was scored by the same harness on the same rows, each at its
own operating point, so the comparison measures the models rather than the
plumbing.

| System | Recall | Precision | Size | Params |
|---|---:|---:|---:|---:|
| **redact** | **88.8** | **99.6** | **11.6 MB** | **23M** |
| GLiNER-PII | 91.1 | 90.4 | 2.3 GB | 570M |
| Rampart | 61.4 | 97.2 | 14.7 MB | 18.5M |
| OpenAI privacy filter | 60.2 | 93.5 | 3 GB | 1.5B |

**Recall** is the share of personal data fully masked (leak-safe), macro-averaged
over WikiANN, MultiNERD and a format-valid structured-PII set across 24 EU
languages. **Precision** is the share of masked spans that were really personal
data, on the structured set. Size is the Apple build; the Android and web build
is 24.5 MB.

Not masking ordinary words matters as much as catching real ones, because a
false positive corrupts the text a downstream model receives. On an 11,528-row
negative set across 27 languages, built to provoke exactly that (sentence-initial
capitals, ALL-CAPS input, month and weekday names, UI vocabulary, bare numbers,
company names), 94.1% of rows come back untouched.

### AWS Comprehend, English only

Comprehend is the other service teams weigh, and it is not in the table above
because its PII API **only accepts English** — every other language code is
refused outright, so there is no way to run it on the other 23. Scored on the
same English rows:

| System | Names (WikiANN) | Names (MultiNERD) | Structured | English composite |
|---|---:|---:|---:|---:|
| redact | 69.5 | 94.9 | **95.0** | 86.5 |
| AWS Comprehend | **84.3** | **98.5** | 91.9 | **91.6** |

Leak-safe recall; precision is the same for both (99.8 against 100.0). On English
names Comprehend is ahead of us. It also runs in the cloud, bills per call, and
covers one of the 27 languages listed below.

## Languages

**27 languages**: every official EU language, plus 3 more.
Latin, Greek and Cyrillic scripts.

### The 24 EU languages

| Code | Language |
|---|---|
| `bg` | Bulgarian |
| `hr` | Croatian |
| `cs` | Czech |
| `da` | Danish |
| `nl` | Dutch |
| `en` | English |
| `et` | Estonian |
| `fi` | Finnish |
| `fr` | French |
| `de` | German |
| `el` | Greek |
| `hu` | Hungarian |
| `ga` | Irish |
| `it` | Italian |
| `lv` | Latvian |
| `lt` | Lithuanian |
| `mt` | Maltese |
| `pl` | Polish |
| `pt` | Portuguese |
| `ro` | Romanian |
| `sk` | Slovak |
| `sl` | Slovenian |
| `es` | Spanish |
| `sv` | Swedish |

### Beyond the EU

| Code | Language |
|---|---|
| `nb` | Norwegian Bokmål |
| `nn` | Norwegian Nynorsk |
| `is` | Icelandic |

Coverage is not uniform: the largest EU languages are the strongest, and Maltese
and Irish are the weakest of the 24. The per-language detection numbers are in
the benchmark data.

## Architecture

- **Encoder:** Multilingual-MiniLM (XLM-R lineage) truncated to 6 layers with an
  EU-script-trimmed vocab (~23 M params), fine-tuned for BIOES tagging.
- **Deterministic layer:** a pure-stdlib post-processor owns high-confidence
  structured labels (email, URL, IP/MAC, card, IBAN/BIC, VIN, SSN, routing,
  tax id, government id, passport, driving licence, IMEI) with real validation
  (Luhn, ISO-13616 IBAN, ISO-7064, per-country checksums) and reconciles them
  with the model's contextual predictions. EU structured coverage includes
  **checksum-validated national IDs for all 24 EU countries, all 27 EU VAT
  numbers, IMEI, and per-country driving-licence numbers**. The same layer is
  ported byte-for-byte to the JS and Swift runtimes (span-for-span parity).
- Recommended runtime: `min_score = 0.6`, `max_length = 256`, `stride = 64`.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for
most apps; a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.
