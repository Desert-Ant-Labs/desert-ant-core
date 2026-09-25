# Schemer: design notes

How to use it is [docs/models/schemer.md](../../docs/models/schemer.md). This is
why the target is shaped the way it is, for whoever changes it next.

One Swift core behind three surfaces: this target, `@desert-ant-labs/schemer`
(packages/schemer-node) and `ai.desertant:schemer` (packages/schemer-kotlin).
All three drive `Schemer.run(input:options:)` in `Binding.swift`; the payloads
are documented there once and mirrored in `codec.js` and `Schemer.kt`.

## The graphs

Three files per backend, named alike on both (`Catalog.swift`):

```
schemer-encoder   encode_32 | encode_256 | encode_1216   joint [anchor ||| schema ||| text]
schemer-decode    decode_256 | decode_1216               reader + every static head, 27 outputs
schemer-label                                            dual + prototype logits over 16 values
embeddings.q      103324 x 768 int8 table (not a graph)
schemer_tokenizer.bin
```

A window is a Core ML multifunction package's function or a LiteRT model's
signature, over one copy of the weights, and the session factory takes the one
name for either. Static shapes are a hardware requirement: the Neural Engine has
no dynamic shapes. `Shapes.window(for:)` picks the smallest window that holds
the record; past the largest, text is truncated.

The LiteRT files are dynamic-range int8, not weight-only: XNNPACK dequantizes a
weight-only file to fp32 once per signature, which put one 256 pass of the
encoder at 2.4 GB RSS, got the Android suite OOM-killed, and made LiteRT.js
abort compiling it in the browser. Dynamic-range keeps the int8 weights (0.54
GB) and is faster. The LiteRT 1216 window is exported query-blocked, which
lowers its peak memory by a third; the arithmetic is identical.

Built by schemer-training's `tools/release/build_bundles.py` and laid out for
the Hub by `tools/release/stage_hub.py`.

**All Core ML graphs plan 100% on the Neural Engine**, verified per op with
`MLComputePlan` on an M1 (schemer-training docs/ane-residency-results.md). The
decode graph fuses the reader and every head whose shape does not depend on the
label value set into one program, so the dispatch floor is paid once per field.

**The embedding table is a file, not a graph.** 80 MB against a 2 MB on-chip
working set, `gather` has a narrow envelope on the engine, and CPU-only measured
fastest for it anyway. A lookup is a memcpy.

**The harness is ordinary code on purpose.** Turning "1.234,56" into 1234.56 is
simply correct, where a learned digit decoder mis-scales. The model locates;
`Harness` converts. Same for BIO span decoding, boundary trimming, relative
dates (`RelativeDates.swift`, 13 languages) and ISO composition. It ports the
reference harness (`predict_for_schema` in schemer-training) branch for branch,
including its quirks, because the reference is what was evaluated.

**One extraction is one billed call** (`InferenceContext.withCallGroup`), though
it runs four to six graph passes per field.

**Arrays of objects are harness, not model.** `Nested.swift` ports the
reference's segment-and-recurse rule for rule: split into candidate spans, run
the flat pipeline on each with the item's properties, keep a candidate when its
first string property is found, drop a candidate that spans tighter ones which
found items, drop duplicates, partial copies and chimeras, and return items in
text order. Segmentation and assembly are checked against the reference's own
functions with no model (`schemer_segments.json`, which also holds the
stated-time parser's cases), and the whole path against the reference on 200
held-out nested records.

## Cost

The encoder runs once per field: the joint input embeds that field's schema
summary, so its encoding is not reusable across fields. Warm p50 for a 4-field
record on a base M1, release build: 84 ms short, 1.2 s for a long document.
Query encodings (descriptions, head queries, label values) are cached per
string. The first use of each graph on the Neural Engine compiles it for the
device, once per install; `prewarm()` moves that off the first extraction. On
LiteRT (CPU, XNNPACK) a 256 pass is 0.3 s natively on an M1 and about 1.3 s
single-threaded in the browser; a 1216 pass 3.4 s and 9 s.

Memory: sessions load lazily, so a workload that never sees a long document
never loads the 1216 functions.

## Conformance

Everything is checked against the reference, never against a port of it. A
Python port of the harness once agreed with this SDK 180/180 while both
extracted "Bottle" where the reference extracts "Blue Bottle": a fixture is only
worth what its source is.

* **Fields**: `Tests/SchemerTests/Resources/schemer_golden.json`, the reference
  harness's answers on the exported graphs per backend (Core ML, LiteRT), over
  records written for the purpose. Every SDK suite checks it field by field;
  on the M1 and every ARM64 host measured they match on every field. A suite
  allows 2% to differ on other ARM64 hardware, 5% in a simulator or the
  browser, and 10% on x86_64, where the LiteRT int8 kernels round boundary
  fields differently (5 to 8 of 115 measured), and prints each one. Against 120 held-out eval records the Swift SDK
  matches the reference on 732 of 732 fields
  (`SCHEMER_REFERENCE_FIXTURES`, see ConformanceTests.swift).
* **Tokenizer**: `schemer_tokenizer_fixtures.json`, 466 cases in 13 languages
  with emoji, byte fallback, added tokens and truncation: ids, char offsets
  (Unicode scalars, as Python indexes a `str`), the pruned-vocabulary remap and
  decode, bit for bit against the HF fast tokenizer.
* **Wire**: `schemer_wire.*` are the bytes the JS encoder writes; the Swift
  suite decodes them and the Kotlin suite writes them.

## Known gaps

* A single nested object (`type: "object"`) and objects inside objects are
  not supported; neither is the reference.
* `mode` (the eval corpus's "identifier", "generate") is not expressible.
* Labels take at most 16 values (the compiled label graph's width), and always
  choose one: this release has no label abstention.
* A number field that is not stated nullable composes a value when the text has
  none, as the reference does.
