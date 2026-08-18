"""Generate detection_vectors.json: the head's output, pinned.

    python3 Tools/tongue/gen_detection_vectors.py --reference ../tongue-training

The normalizer, hasher and router each have vectors. The head did not, so no test
in any port asserted a single probability — which is how three ports came to
disagree on `detection.language` for hashtag input while every suite stayed green.

This is a fourth implementation, written from the algorithm the ports document
rather than from any of them: sorted bucket order, float32 multiply and add
throughout, the softmax shift in float32. It reads the shipped weights directly.
If it agrees with Swift, Kotlin and JavaScript then four independent
implementations agree, which is worth more than three ports agreeing with a
vector file one of them produced.
"""
from __future__ import annotations

import argparse
import json
import math
import pathlib
import struct
import sys

import numpy as np

CASES = [
    "kann ich das haben",
    "je voudrais un café au lait",
    "quanto costa il biglietto",
    "la casa",
    "hi i am",
    "saya tidak tahu di mana dia tinggal sekarang",
    "où est la gare",
    "hvor er stationen",
    "gdzie jest dworzec",
    "привет как твои дела",
    "мен сені жақсы көремін",
    "мовчання золото",
    "hello #नमस्ते world",
    "hello #مَرْحَبا world",
    "thanks for the tour @москва",
    "ΟΔΟΣ ΑΘΗΝΑΣ",
    "ñ ø ő ț å æ",
    "Samsung Galaxy",
    "xy",
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--reference", type=pathlib.Path, default=pathlib.Path("../tongue-training"))
    ap.add_argument("--weights", type=pathlib.Path, default=pathlib.Path("Sources/Tongue/Resources/tongue_int8.bin"))
    ap.add_argument("--meta", type=pathlib.Path, default=pathlib.Path("Sources/Tongue/Resources/tongue_meta.json"))
    ap.add_argument("--out", type=pathlib.Path, default=pathlib.Path("detection_vectors.json"))
    args = ap.parse_args()

    sys.path.insert(0, str((args.reference / "src").resolve()))
    from tongue_training.hashing import fnv1a  # noqa: E402
    from tongue_training.normalize import normalize  # noqa: E402
    from tongue_training.script import route  # noqa: E402

    meta = json.loads(args.meta.read_text(encoding="utf-8"))
    labels: list[str] = meta["labels"]
    latin: list[str] = list(meta.get("latin_labels") or labels)
    buckets_n: int = meta["num_buckets"]
    dim: int = meta["dim"]
    orders = tuple(meta["ngram_orders"])
    scale = np.float32(meta["embed_scale"])

    blob = args.weights.read_bytes()
    n_emb = buckets_n * dim
    n_w = len(labels) * dim
    emb = np.frombuffer(blob, dtype=np.int8, count=n_emb).reshape(buckets_n, dim)
    lin_w = np.frombuffer(blob, dtype=np.float32, count=n_w, offset=n_emb).reshape(len(labels), dim)
    lin_b = np.frombuffer(blob, dtype=np.float32, count=len(labels), offset=n_emb + n_w * 4)

    def bag(text: str) -> dict[int, int]:
        """Bucket counts, matching Hashing.buckets in every port."""
        counts: dict[int, int] = {}
        for token in text.split(" "):
            if not token:
                continue
            marked = [0x5E, *[ord(c) for c in token], 0x24]
            for order in orders:
                for start in range(0, len(marked) - order + 1):
                    h = fnv1a("".join(chr(c) for c in marked[start:start + order]))
                    b = h % buckets_n
                    counts[b] = counts.get(b, 0) + 1
        return counts

    def rank(text: str, allowed: list[str], top_k: int = 3):
        pooled = np.zeros(dim, dtype=np.float32)
        counts = bag(text)
        # Ascending bucket order and float32 throughout: float addition is not
        # associative, so both are part of the answer.
        for bucket in sorted(counts):
            weight = np.float32(np.float32(counts[bucket]) * scale)
            pooled = pooled + (emb[bucket].astype(np.float32) * weight).astype(np.float32)
            pooled = pooled.astype(np.float32)

        keep = set(allowed)
        logits: list[tuple[str, np.float32]] = []
        for j, lang in enumerate(labels):
            if lang not in keep:
                continue
            s = np.float32(lin_b[j])
            row = lin_w[j]
            for k in range(dim):
                s = np.float32(s + np.float32(np.float32(row[k]) * pooled[k]))
            logits.append((lang, s))
        if not logits:
            return []
        mx = max(v for _, v in logits)
        ex = [(lang, math.exp(float(np.float32(v - mx)))) for lang, v in logits]
        total = sum(e for _, e in ex)
        ex.sort(key=lambda pair: -pair[1])
        return [(lang, (e / total if total > 0 else 0.0)) for lang, e in ex[:top_k]]

    def reliability(text: str, ranked) -> str:
        characters = len(text)
        margin = (ranked[0][1] - ranked[1][1]) if len(ranked) > 1 else (ranked[0][1] if ranked else 0.0)
        if characters >= 18 and margin >= 0.30:
            return "confident"
        if characters >= 12 and margin >= 0.20:
            return "likely"
        return "tentative"

    cases = []
    for text in CASES:
        norm = normalize(text)
        verdict, candidates, script = route(norm)
        if not norm:
            cases.append({"input": text, "normalized": "", "language": None,
                          "reliability": "empty", "isTooCloseToCall": False,
                          "candidateLanguages": [], "candidateProbabilities": []})
            continue
        if verdict.value == "decisive" and candidates:
            cases.append({"input": text, "normalized": norm, "language": list(candidates)[0],
                          "reliability": "confident", "isTooCloseToCall": False,
                          "candidateLanguages": [list(candidates)[0]],
                          "candidateProbabilities": [1.0]})
            continue
        allowed = [l for l in labels if l in candidates] if verdict.value == "narrowing" else latin
        ranked = rank(norm, allowed)
        tie = len(ranked) > 1 and (ranked[0][1] - ranked[1][1]) < 0.12
        cases.append({
            "input": text,
            "normalized": norm,
            "language": ranked[0][0] if ranked else None,
            "reliability": reliability(norm, ranked) if ranked else "empty",
            "isTooCloseToCall": tie,
            "candidateLanguages": [l for l, _ in ranked],
            "candidateProbabilities": [p for _, p in ranked],
        })

    payload = {
        "_comment": (
            "Head output, pinned. Written by Tools/tongue/gen_detection_vectors.py, a fourth "
            "implementation of the documented algorithm (sorted bucket order, float32 "
            "multiply and add, float32 softmax shift) reading the shipped weights. "
            "Probabilities are compared with a tolerance because exp() differs in the "
            "last bits between libms; language, reliability and isTooCloseToCall are "
            "exact. Flat parallel arrays so each port reads it with the same minimal "
            "reader it already uses for the other vectors, rather than taking a JSON "
            "dependency. Nothing asserted a probability before this file existed, which is "
            "how the ports came to disagree on hashtag input while every suite passed."
        ),
        "tolerance": 1e-6,
        "cases": cases,
    }
    args.out.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {args.out}: {len(cases)} cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
