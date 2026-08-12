# Tokenizer vocab keying: why the index is on bytes

## The defect

A tokenizer vocab loaded into a `[String: Int]` dictionary is **silently lossy**. Swift `String`
equality is Unicode *canonical equivalence*, not byte equality, so two vocab pieces that differ
in bytes but not in canonical form become one key.

It fails in two directions, and the second is the one a naive audit misses:

- **Eviction.** Two pieces share a canonical form. The later insertion wins, and the loser's id
  becomes unreachable. If the reachable one is not the form NFKC produces, every lookup of that
  word returns the wrong id.
- **False-positive match.** A piece whose own bytes are not NFKC-stable has *no twin at all*, so
  nothing evicted it. Instead a query built from ordinary canonically-ordered text compares equal
  to it, and the lookup hits a piece whose bytes the text never contained.

A pairwise collision scan finds the first and structurally cannot find the second. The correct
definition of the defect is **"pieces whose bytes are not NFKC-stable"**, not "pieces that collide
with another piece".

Measured Aug 2026 across the shipped vocabs:

| vocab | NFKC-unstable pieces | evictions | false-positive traps |
|---|---|---|---|
| xlm-roberta-base (Clips) | **52** | 31 | **21** (mostly Burmese, one Hebrew) |
| emo v0.7.0 | **3** | 2 | 1 (Arabic) |
| redact v0.4.0 | 0 | 0 | 0 |

Redact is clear under both definitions, so its keying change is output-neutral. That is a property
of one pruning run, not of the design.

Provenance, because a stale vocab behind a "needs no change" row is exactly the claim that gets
cited later as evidence. **Clips**: 250,002 pieces, scanned independently from
`release/clip/tokenizer/tokenizer.json` and from the `xlm-roberta-base` snapshot in the HF cache;
the two files differ byte-wise but yield identical counts, so the row does not depend on which is
authoritative. **Emo**: the real cached `emo_tokenizer.bin` for the pinned `v0.7.0`. **Redact**:
the shipping artifact pulled from `desert-ant-labs/redact` at the `v0.4.0` that
`Sources/Redact/Catalog.swift` pins, after an earlier scan turned out to have used a locally
cached v0.2.2; both revisions are byte-identical (`sha256 81bc354d…`), so the tokenizer did not
move and the row holds on the version that ships.

## What this repo does

**All three tokenizers.** `Sources/Clips/Tokenizer.swift`, `Sources/Emo/Tokenizer.swift` and
`Sources/Redact/Tokenizer.swift` index the vocab by UTF-8 bytes, using open addressing over the
container's own byte image rather than a `[String: Int]`. Byte keys cannot collide canonically and
cannot false-positive, so both failure modes go away together. Lookups probe a byte range instead
of building a `String` per probe, which is why bytes are also ~25x faster, and no piece becomes a
`String` at all: ~250k fewer allocations at load for Clips, ~48k for Emo, ~31k for Redact.

They are one decision, not three. The defect belongs to the key type rather than to any one vocab,
and Clips and Redact read the same `RDTK` container from the same builder, so a vocab key has to
mean the same thing in all three. Otherwise the next re-cut vocab reintroduces it in whichever one
was left behind.

What the change means differs per model, and that is the whole story:

| model | keyed on `String` | keyed on bytes |
|---|---|---|
| Clips | does not load at all | loads; reference parity 85/85 |
| Emo | loads, wrong Vietnamese ids | loads; ids match training |
| Redact | correct today | byte-identical output |

For **Clips** the keying is not a preference. The loader guards `parsedIndex.count == count`; with
29 keys collapsed that check can never hold, so a `String`-keyed build of this tokenizer returns
nil from `init?` and **every `Clips` load throws `modelNotFound`**. Reference parity against Python
`transformers` across 13 scripts is **57/85 keyed on `String`, 85/85 keyed on bytes**.

For **Redact** nothing observable moves: 0 of its 31,475 pruned pieces are NFKC-unstable and no two
share a canonical form, so `String` keys and byte keys agree on every query its encoder can build.
That is a proof rather than a sample, and the sample agrees: 88 of 88 corpus texts tokenize
byte-identically before and after. It is worth doing for the speed, for the allocations, and
because the defect otherwise waits in a model whose job is finding names across 27 languages.

**Emo** is the one whose output changes. That is the next section, and it is the only part of this
work that needs a decision rather than a review.

## What this changes for Emo

Emo v0.7.0 degrades quietly rather than failing, because its loader validates only the header and
length and has no count check. Two pieces are evicted and one is a false-positive trap:

| piece | id training assigned | id shipped v0.7.0 produces |
|---|---|---|
| `▁một` ("one/a") | 688 | 39184 |
| `▁ở` ("at/in") | 1493 | 41329 |
| `U+0651 U+064E` (shadda before fatha) | n/a, trap | hit by ordinary vowelized Arabic |

Measured against the real shipped `emo_tokenizer.bin`, this is what byte keying does to its output:

- **Nothing breaks.** Full repo suite passes, 0 failures.
- **Vietnamese:** 10.84% of 16,675 phrases change tokenization. Parity with the training-side
  reference goes **89.16% to 100%**. 155 top-1 label flips (0.93% of Vietnamese); the rest is
  top-5 reordering or confidence-only.
- **Arabic:** 11 of 356,237 non-Vietnamese phrases change (0.0031%), all fatha+shadda, all moving
  *toward* agreement with the training-side tokenizer. **0 top-1 flips.**
- **Everything else is bit-identical.** 356,226 of 356,237 non-Vietnamese rows unchanged.
- **Throughput:** 2,939/s to 69,636/s.

The corrected ids are the ones the checkpoint trained with, so this is a **repair** of the encoder
rather than a retune of the model, and **a retrain is not indicated**. The composed and decomposed
rows are genuinely different vectors in the frozen embedder (cosine 0.21 and 0.38), and both
decomposed pieces sit at the vocab's floor unigram score, identical to unk.
`testVietnameseVocabPiecesAreReachable` pins 688 and 1493 against the cached artifact, so a re-cut
vocab that moves them fails loudly.

### The release caveat, which is the model owner's call

What is missing is evidence of *improvement* rather than *conformance*: measured against the
corpus's own labels the change is flat (McNemar p=0.37 / 0.09 / 0.47), and **0 of the 99 Vietnamese
rows in the held-out `emoji-eval` set contain either word**, so the existing eval could not have
caught the defect and cannot measure the fix.

Emo v0.7.0 is already shipped, so **the core release that carries this changes emo's Vietnamese
output in the field**. Before that release ships, build a Vietnamese eval slice that contains `một`
and `ở` and read the 155 flips blind. That is the model owner's decision, not this repo's.

Tracked at [Desert-Ant-Labs/lab#8](https://github.com/Desert-Ant-Labs/lab/issues/8).

## The rule

Any dictionary keyed on `String` that holds a tokenizer vocab, a label set or a class map is
silently lossy for non-Latin scripts. Key on bytes. And test the consumer path against the **real
published artifact** on non-Latin text: the published `clip_tokenizer.bin` is byte-perfect, and a
`String`-keyed loader still cannot read it.
