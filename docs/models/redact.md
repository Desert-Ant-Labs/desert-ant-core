<!-- model:start -->
# Redact

Filter PII on the device.

Multilingual on-device PII detection and redaction.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Languages** | 27 |
| **Weights** | [v0.4.2](https://huggingface.co/desert-ant-labs/redact/tree/v0.4.2) |
| **Demo** | https://desertant.com/models/redact/ |
<!-- model:end -->

Strip names, addresses, emails, phone numbers, cards, IBANs and national IDs out of text before it leaves the device, across 27 [languages](#languages). Redact replaces each one with a placeholder, so you can send the redacted text to an LLM and put the original values back in its reply. A token classifier finds names and addresses, and a pattern layer catches structured IDs. The model is 11.6MB as 4-bit Core ML on Apple platforms, or 24.5MB as int8 LiteRT on Android, Linux, Windows, Node and the web.

> `"Call Anna Kovács at anna@example.hu, IBAN GB29NWBK60161331926819"` →
> `"Call [GIVEN_NAME_1] [SURNAME_1] at [EMAIL_1], IBAN [BANK_ACCOUNT_1]"`

## Try it

- **Live demo:** [desert-ant-labs/redact-demo](https://huggingface.co/spaces/desert-ant-labs/redact-demo): paste text and watch PII get highlighted or masked, fully in your browser.

<!-- model-install:start -->
## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "4.2.3")
```

Then add the `Redact` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:redact:4.2.3")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/redact @litertjs/core   # browser
npm i @desert-ant-labs/redact                  # Node, prebuilt native core
```
<!-- model-install:end -->

## Usage

### Swift

```swift
import Redact

let redact = Redact()
let result = try await redact.redaction(of: "Email Anna Kovács at anna@example.hu.")

print(result.redactedText)
// Email [GIVEN_NAME_1] [SURNAME_1] at [EMAIL_1].

for item in result.items {
    print(item.label.displayName, item.original, item.placeholder, item.confidence)
}

let reply = try await myLLM.rewrite(result.redactedText)
let restored = result.restore(reply)
```

Filter by category, or raise the confidence floor:

```swift
let options = Options(minimumConfidence: 0.7, labels: [.email, .phone, .creditCard])
let contactOnly = try await redact.redaction(of: text, options: options)
```

### Kotlin

```kotlin
import ai.desertant.redact.Redact

Redact(context).use { redact ->
    val result = redact.redaction("Email Anna Kovács at anna@example.hu.")
    println(result.redactedText)                 // Email [GIVEN_NAME_1] [SURNAME_1] at [EMAIL_1].
    val restored = result.restore(llmReply)
}
```

### JavaScript

```ts
import { Redact } from "@desert-ant-labs/redact";     // browser
// import { Redact } from "@desert-ant-labs/redact/native"; // server-side Node

const redact = await Redact.load();
const result = await redact.redaction("Email Anna Kovács at anna@example.hu.");
console.log(result.redactedText);   // Email [GIVEN_NAME_1] [SURNAME_1] at [EMAIL_1].
const restored = result.restore(llmReply);
redact.dispose();
```

### Loading the model

The SDK downloads the weights from Hugging Face on first use and caches them. To prefetch the weights or ship them with your app, see [model downloads and caching](../../README.md#model-downloads-and-caching).

### Runtime settings

By default the SDK drops model detections with a confidence below 0.6 (`minimumConfidence`). Pattern matches for structured data, like emails and card numbers, always apply. The SDK splits long text into 256-token windows that overlap by 64 tokens, so an entity on a window edge still comes back whole.

## Labels

Redact detects 20 labels:

`GIVEN_NAME`, `SURNAME`, `STREET_NAME`, `BUILDING_NUMBER`, `SECONDARY_ADDRESS`, `CITY`, `STATE`, `ZIP_CODE`, `EMAIL`, `PHONE`, `CREDIT_CARD`, `BANK_ACCOUNT`, `ROUTING_NUMBER`, `IP_ADDRESS`, `URL`, `GOVERNMENT_ID`, `PASSPORT`, `DRIVERS_LICENSE`, `TAX_ID`, `SSN`.

Redact detects `ORG` (an organization or company name), but doesn't redact it by default, because a company isn't a natural person. With the `ORG` label, Redact recognizes names like `Silverfin`, `Odoo` or `Visma Nova` as organizations and doesn't mislabel them as a `SURNAME`. To redact organizations, pass `ORG` in the SDK's `labels` option.

Redact also flags `IMEI` (a device identifier), with a pattern check instead of the model. The check flags a 15-digit number only when the number passes the Luhn checksum and sits within 32 characters of the word "IMEI".

## How it compares

We scored every system below with the same scoring code, on the same rows. Each system ran at its own operating point.

| System | Recall | Precision | Size | Params |
|---|---:|---:|---:|---:|
| **redact** | **88.8** | **99.6** | **11.6MB** | **23M** |
| GLiNER-PII | 91.1 | 90.4 | 2.3GB | 570M |
| Rampart | 61.4 | 97.2 | 14.7MB | 18.5M |
| OpenAI privacy filter | 60.2 | 93.5 | 3GB | 1.5B |

Recall is the share of personal data a system masks fully, so none of it leaks. We macro-average recall over WikiANN, MultiNERD and a format-valid structured-PII set, across 24 EU languages. Precision is the share of masked spans that really were personal data, measured on the structured set. The size column shows the Core ML build that Redact uses on Apple platforms. On Android, Linux, Windows, the browser and Node, Redact uses the LiteRT build, which is 24.5MB.

Every false positive corrupts the text your LLM receives. We test for false positives on 11,528 rows in 27 languages that hold no personal data but look like they might: sentence-initial capitals, ALL-CAPS input, month and weekday names, UI vocabulary, bare numbers and company names. Redact returns 94.1% of those rows untouched.

### AWS Comprehend, English only

AWS Comprehend isn't in the table above, because its PII API accepts only English. The API refuses every other language code, so we couldn't run Comprehend on the other 23 languages. Here are both systems on the same English rows:

| System | Names (WikiANN) | Names (MultiNERD) | Structured | English composite |
|---|---:|---:|---:|---:|
| redact | 69.5 | 94.9 | **95.0** | 86.5 |
| AWS Comprehend | **84.3** | **98.5** | 91.9 | **91.6** |

The table shows recall. Precision is close for both systems, 99.8 against 100.0. Comprehend is ahead of Redact on English names, and Redact is ahead on structured data. Comprehend runs in the cloud and bills per call.

## Languages

Redact supports 27 languages: every official EU language, plus 3 more. The 27 languages use the Latin, Greek and Cyrillic scripts.

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

Redact is most accurate on the largest EU languages. Maltese and Irish are the weakest of the 24. The per-language detection numbers are in the benchmark data.

<!-- model-footer:start -->
## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/). Free for most
apps, and a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.

Third-party notices for the weights: [`THIRD_PARTY_NOTICES.md`](https://huggingface.co/desert-ant-labs/redact/blob/main/THIRD_PARTY_NOTICES.md).

## Citation

```bibtex
@software{redact_2026,
  title  = {Redact: Multilingual on-device PII detection and redaction},
  author = {Desert Ant Labs},
  year   = {2026},
  url    = {https://huggingface.co/desert-ant-labs/redact},
}
```

---

© 2026 Desert Ant Labs · <https://desertant.com>
<!-- model-footer:end -->
