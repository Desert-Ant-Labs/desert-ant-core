# Clips: integrating the SDK

What a host app needs to select a transcript's best moments on device. Every command and number
here was run against the shipping bytes on 2026-08-11; nothing is aspirational.

## The whole API

```swift
import Clips

let clipper = Clips(directory: "/path/to/model")   // nil = managed cache + download
let clips = try await clipper.clips(in: sentences) // [String] in, [Clip] out
```

`Clip` carries `sentenceIDs`, `text`, `score`, `percentile`, `estimatedDurationSec`, and an
`id`. Clips come back **best first** and never overlap.

**Rank on `percentile`, not `score`.** The scorer is trained with within-video ranking, and
per-video 95th-percentile raw scores span 0.33 to 0.95, so an absolute threshold on `score`
means something different on every video. `percentile` is comparable across videos; `score` is
comparable only within one.

## Shipping the model with the app

The package bundles no artifact. Point `directory` at a folder you populate and it is used
as-is, offline, with nothing downloaded — `isDownloaded()` returns true immediately.

The folder needs exactly two entries, named as `ClipModel` declares them:

```
clips.mlmodelc/        the compiled multifunction package (select + score)
clip_tokenizer.bin     XLM-R SentencePiece Unigram vocab, 250,002 pieces
```

Build both from `clips-training`:

```bash
python python/build_tokenizer_bin.py release/clip/tokenizer/tokenizer.json \
       -o <dir>/clip_tokenizer.bin
xcrun coremlcompiler compile \
       release/clip-mf/win256/int8_linear_perchannel_score256.mlpackage <dir>
mv <dir>/int8_linear_perchannel_score256.mlmodelc <dir>/clips.mlmodelc
```

A staged copy already exists at `clips-training/release/clip-sdk/`, with a `manifest.json`
recording the checkpoint digest, both graph shapes and the tokenizer hash.

**The tokenizer must be the one the model trained with.** Token ids fix where truncation falls,
so a substituted vocab produces finite, plausible, wrong output rather than an error.

## What ships, and why that one

`int8_linear_perchannel`, **284 MB**, `select` at [16,128] and `score` at [16,256], from
checkpoint `fe11c7852ef0421e`.

It ties fp16 on judged clips in every stratum — good clips per video and dross clips per video,
paired — at half the size. int4 is 2.0-2.7x *slower* on the Neural Engine with a selection that
barely resembles its own reference. Every LUT scheme silently doubles the trunk. The full
argument and its reproduction steps are in `clips-training/docs/quant-decision.md`.

## Measured behaviour

Public API, `Clips(directory:)`, `CPU_AND_NE`, M3 Ultra:

| transcript | clips | time |
|---|---|---|
| n=11 | 3 | 36.9 s **first call** |
| n=14 | 4 | 0.58 s |
| n=19 | 6 | 1.09 s |
| n=23 | 7 | 1.60 s |

**The first call pays a one-off Neural Engine compile of roughly 30 seconds**, cached
afterwards. Call `download(progress:)` — which also warms the load — off the critical path, or
the first selection in your app looks broken.

End to end per video on the same host, by stratum: **0.39 s** short, **1.75 s** medium,
**3.34 s** long, **4.64 s** podcast at the 128 window; the shipping 256 window costs +75% to
+134% on top. A phone is not this host: treat these as shape, not as device figures.

## How many clips you get

An **upper limit set by duration**, never a quota: 8 under 5 minutes, 11 to 10, 13 to 30, 14
beyond, at 2.5 words per second. A transcript that supports fewer good moments returns fewer,
and that is correct rather than a shortfall — measured above, an 11-sentence transcript returns
3 against a ceiling of 8.

The rule is shared with `clips-training`'s `construct.clip_budget` and the two must not drift.
They did: this SDK used `n / 4` capped at 12 while the offline path capped at a literal 6, so
identical input produced different clip counts on the two paths and only one of them was ever
evaluated.

Clips never overlap, and near-duplicates are dropped at a Jaccard threshold of 0.5. If your
product wants overlapping alternatives to choose between, that is a pipeline change and not a
parameter — the non-overlap constraint is what caps output on short transcripts.

## Things that will bite

- **Sentences are truncated at 64 tokens for the selector**, not at the graph's 128. That is the
  window the saliency heads were trained at. The two numbers are separate parameters
  (`Model.sentenceTokens` and the buffer stride) because conflating them ran the heads
  off-distribution on 76% of a holdout and changed the emitted clip set on 30% of it.
- **Both graph widths are read from the loaded artifact**, so one binary serves a 128 or a 256
  package. Do not reintroduce a hardcoded width: it truncates every candidate on the wider
  package and returns no error.
- **A wrapper that forgets `inputWidth` breaks this silently.** The protocol has a `nil`
  default, so a session wrapper that fails to forward it compiles clean and every caller falls
  back to a constant. That happened with `TrackedSession` and cost a run.
- **Pin `.cpuAndNeuralEngine`.** `.all` is ~4% slower on both test phones, and the compute-unit
  request is advisory — the flag you pass is not evidence of where it ran.

## What has NOT been verified

- **No on-device run.** Every number here is an M3 Ultra. `ios-demo/RuntimeBench` in
  `clips-training` is the harness for a real device and has not been run against this artifact.
- **No human read of these clips.** Quality rests on a model judge over 20 videos; the project's
  own rule puts a human blind read above every model judge.
- **Android and Linux are unbuilt.** `ClipModel` declares `.tflite` exports for those platforms
  and no LiteRT export of this checkpoint exists.
- **Nothing is published.** `ClipModel.revision` is `main` and the Hub carries no tag whose
  artifacts match these names, so `Clips()` with no `directory` will not resolve. Use
  `directory:` until a tagged release exists.
