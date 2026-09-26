<!-- model:start -->
# Schemer

Extract typed JSON from any text.

On-device structured extraction into a caller-supplied JSON schema.

| | |
| --- | --- |
| **Platforms** | iOS, macOS, tvOS, visionOS, Android, Linux, Windows, Browser, Node |
| **Languages** | 13 |
| **Weights** | [v1.1.0](https://huggingface.co/desert-ant-labs/schemer) |
| **Demo** | https://desertant.com/models/schemer/ |

## Install

**Swift** ([requirements](../../README.md#swift))

```swift
.package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "3.5.0")
```

Then add the `Schemer` product to your target.

**Kotlin** ([requirements](../../README.md#android))

```kotlin
implementation("ai.desertant:schemer:3.5.0")
```

**JavaScript** ([requirements](../../README.md#javascript-and-typescript))

```bash
npm i @desert-ant-labs/schemer @litertjs/core   # browser
npm i @desert-ant-labs/schemer                  # Node, prebuilt native core
```
<!-- model:end -->

## Usage

Give Schemer text and a schema; it returns one typed value per field, in schema
order. Nothing is generated: each field is decoded by a head built for its
type, so a string is always a literal span of the input, a label is always one
of the values you declared, and a field the text does not state comes back
null rather than invented (see the table below for how each type says so).

### Swift

```swift
import Schemer

let schemer = Schemer()
let schema: Schema = [
    .string("merchant", describe: "the shop or vendor"),
    .number("amount", describe: "total paid", nullable: true, unit: "currency"),
    .boolean("reimbursable"),
    .label("category", values: ["food", "travel", "office"]),
    .datetime("when"),
    .array("attendees", describe: "people present"),
]
let out = try await schemer.extract(from: text, schema: schema)
out["amount"]        // .number(18.5)
print(out.json)      // {"merchant": "Blue Bottle", "amount": 18.5, ...}
```

The first use of each graph on the Neural Engine compiles it for the device,
once per install, and it is slow: about 30 seconds before the first short
record on an M1, and longer before the first long document. Call
`try await schemer.prewarm()` after `download()`, during onboarding, so the
first extraction is fast.

### Kotlin

```kotlin
import ai.desertant.schemer.Field
import ai.desertant.schemer.Schemer

Schemer(context).use { schemer ->
    val out = schemer.extract(text, listOf(
        Field.Text("merchant", describe = "the shop or vendor"),
        Field.Number("amount", describe = "total paid", nullable = true, unit = "currency"),
        Field.Bool("reimbursable"),
        Field.Label("category", listOf("food", "travel", "office")),
    ))
    out["amount"]        // Value.Number(18.5)
    out.toAnyMap()       // {merchant=Blue Bottle, amount=18.5, ...}
}
```

### JavaScript

```ts
import { Schemer } from "@desert-ant-labs/schemer";         // browser
// import { Schemer } from "@desert-ant-labs/schemer/native"; // server-side Node

const schemer = await Schemer.load();
const out = await schemer.extract(text, {
  merchant: { type: "string", describe: "the shop or vendor" },
  amount: { type: "number", describe: "total paid", nullable: true, unit: "currency" },
  reimbursable: "boolean",
  category: { type: "label", values: ["food", "travel", "office"] },
});
// { merchant: "Blue Bottle", amount: 18.5, reimbursable: true, category: "food" }
schemer.dispose();
```

A schema is an object keyed by field name, or an array of `{ name, type, ... }`
when you want the order explicit.

### Fields

| Type | Returns | When the text does not say | Options |
| --- | --- | --- | --- |
| `string` | a literal span of the text | null | |
| `number` | a number, parsed in any of the supported locales | null if `nullable: true`, else 0 | `min`, `max`, `unit` |
| `boolean` | true or false | null | |
| `datetime` | ISO-8601, `YYYY-MM-DDTHH:MM` | null | |
| `label` | one of `values` | the closest value: labels do not abstain | `values`, at most 16 |
| `array` | zero or more literal spans | empty | |
| array of objects | zero or more objects, each with only the properties the text states | empty | `properties` |

Every field also takes `describe` and `nullable`:

* `describe` is read by the model. "the shop or vendor" beats "merchant name".
* `nullable: true` lets a number come back null, and tells the number and
  datetime heads that absence is an expected answer, so it is not the same as
  leaving it unset. Declare it on any optional number.
* `min` and `max` clamp a number and, with `unit` ("currency", "kg", "hour"),
  are read by the number head.

### Lists of objects

A field can be a list of objects: order lines, the stops of a trip, action
items. Declare its properties; each item comes back with the ones the text
states.

```swift
let out = try await schemer.extract(from: "2 ergonomic chairs at 189.00 each, 1 standing desk for 540.00", schema: [
    .objects("lines", properties: [
        .string("item", describe: "product"),
        .number("quantity", describe: "how many", min: 1, max: 99),
        .number("unit_price", describe: "price per unit", unit: "currency"),
    ]),
])
// lines: [{item: "ergonomic chairs", quantity: 2, unit_price: 189},
//         {item: "standing desk", quantity: 1, unit_price: 540}]
```

```kotlin
Field.Objects("lines", listOf(Field.Text("item"), Field.Number("quantity", min = 1.0)))
```

```js
{ lines: { type: "array", items: { type: "object", properties: {
    item: { type: "string", describe: "product" },
    quantity: { type: "number", min: 1, max: 99 },
} } } }
```

There is no model head for this. The text is split into candidate items
(sentences, then list separators such as commas, `;`, `then`, numbered items
and their equivalents in the supported languages), every property is extracted
from each candidate, and the results are assembled: a candidate becomes an item
when its first string property is found; a candidate that spans tighter ones
is dropped in their favour, as are duplicates and partial copies; and items
come back in the order the text states them. So it works well where each item has its own clause or list entry,
and less well where items share one ("Leo, 7, loves football, and Maya, 4,
likes drawing" can mix their fields). It costs one pass per property per
candidate, so a long list is slower than a flat field. Properties are flat:
an object inside an object is not supported.

### Dates

Relative expressions ("tomorrow at 9:30", "am Freitag", "até quarta-feira") resolve against
`now`, which defaults to the device clock. It is read as a day in the device's
time zone, so "yesterday" just after midnight is the day before the user's
today. Pass it to make results reproducible: `extract(from:schema:now:)` in
Swift, the `now` argument in Kotlin, and `{ now: "2026-03-10" }` (or a `Date`)
in JavaScript.

A datetime always carries a time. When the text states one ("at 11pm",
"14:30 Uhr", "下午3点半"), that is the time; when it states none ("am
Freitag"), the time is the model's guess and is not meaningful.

### Long text

Text is read in windows of 256 or 1216 tokens, the smallest that fits; past
1216 tokens (schema included) it is truncated, and the result says so:
`truncated` on the `Extraction` in Swift and Kotlin, and `result[TRUNCATED]` in
JavaScript. A value stated only past that point comes back null. The encoder runs once per field, so cost grows
with the number of fields as well as the length: on an M1 a short four-field
record takes about 85 ms on the Neural Engine, and a long document about 1.2 s.
The browser runs on the CPU in single-threaded WebAssembly, about 1.3 s a field
for short text and 9 s a field for a long document.

### Checking a schema

`extract` rejects a schema the runtime cannot honor (a duplicate name, a label
field with no values or more than 16, a number range that is not finite or has
`min` above `max`, objects inside objects). To check one before the model is
downloaded: `try schema.validate()` in Swift, `Schemer.validate(schema)` in
Kotlin and JavaScript.

### Loading the model

The weights are fetched from the Hub on first use and cached. See
[model downloads and caching](../../README.md#model-downloads-and-caching).

## Files

| File | Format | Size | Contents |
|---|---|---:|---|
| `schemer-encoder.mlmodelc` | Compiled Core ML, 8-bit palettized, multifunction | 114MB | The encoder, one function per window (32, 256, 1216), 100% Neural Engine |
| `schemer-decode.mlmodelc` | Compiled Core ML, 8-bit palettized, multifunction | 20MB | The reader and every typed head, fused (256, 1216) |
| `schemer-label.mlmodelc` | Compiled Core ML, 8-bit palettized | 3MB | Label scoring over up to 16 values |
| `schemer-encoder.tflite` | LiteRT, dynamic-range int8, 3 signatures | 117MB | The encoder, for Android, Linux, Windows, Node there, and the browser |
| `schemer-decode.tflite` | LiteRT, dynamic-range int8, 2 signatures | 20MB | The reader and every typed head |
| `schemer-label.tflite` | LiteRT, dynamic-range int8 | 3MB | Label scoring |
| `embeddings.q` | int8 table | 80MB | Token embeddings, looked up on the CPU |
| `schemer_tokenizer.bin` | binary | 11MB | Tokenizer vocabulary, merges and the vocabulary remap |

Each platform downloads only its own files, about 230MB. The SDKs run the same
harness the model was evaluated with, so a value here is the value the model was
measured on.

## License

[Desert Ant Labs Source-Available License](https://license.desertant.com/1.0). Free for
most apps; a commercial license is required at scale. Full terms are at the link.
Licensing: <licensing@desertant.com>.
