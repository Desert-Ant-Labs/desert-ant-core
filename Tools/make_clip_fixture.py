#!/usr/bin/env python3
"""Regenerate `Tests/ClipsTests/Resources/clips-multifunction.mlmodelc`.

    uv run --python 3.11 --with "coremltools==9.0" --with "torch==2.6.0" --with numpy \
        python tools/make_clip_fixture.py

The fixture is a weightless multifunction package carrying the SHIPPING SIGNATURE and none of
the shipping weights: `select` and `score` at the shipping shapes, with `select` as the
default function. It exists so `ClipsTests` can prove the loading contract -- that a path
names the file and not the graph, and that reaching a function needs `functionName` -- without
a 271 MB asset in the repo.

It had no producer before this file. It was a committed binary encoding the old single-shape
signature, so when the scorer moved to its own window the fixture failed and there was no way
to regenerate it except by hand. A test fixture that pins a signature has to be rebuildable
from the signature, or it pins whatever it happened to be built from.

The two shapes are the whole point of the fixture now. A single-shape fixture cannot catch the
defect this package is most likely to have: feeding one function the other's width. That
mistake returns finite numbers from a scrambled batch, so only a shape mismatch at the
boundary makes it loud.
"""
from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from coremltools.models.utils import MultiFunctionDescriptor, save_multifunction

OUT = Path(__file__).resolve().parents[1] / "Tests/ClipsTests/Resources/clips-multifunction.mlmodelc"
#: Must track `Model.seqLen` / `Model.scoreSeqLen`. Both are 128 today; the two-shape
#: path is exercised by keeping them separate constants rather than by shipping a split.
B, L_SEL, L_SCORE, N_DISC = 16, 128, 128, 5


class Selector(torch.nn.Module):
    """Three [B] outputs from the selector's three inputs. Every input is consumed, so a
    dropped or mis-bound input changes the answer rather than being silently ignored."""

    def forward(self, ids, mask, disc):
        base = (ids * mask).float().mean(dim=1) / 1000.0 + disc.sum(dim=1) * 0.01
        return torch.sigmoid(base), torch.sigmoid(base * 0.5), torch.sigmoid(-base)


class Scorer(torch.nn.Module):
    """One [B] output, at the SCORER's own width."""

    def forward(self, ids, mask):
        return torch.tanh((ids * mask).float().mean(dim=1) / 1000.0)


def convert(module, args, names, outputs):
    exported = torch.export.export(module, args).run_decompositions({})
    shapes = {n: tuple(t.shape) for n, t in zip(names, args)}
    dtypes = {"ids": np.int32, "mask": np.int32, "disc": np.float32}
    return ct.convert(
        exported,
        inputs=[ct.TensorType(name=n, shape=shapes[n], dtype=dtypes[n]) for n in names],
        outputs=[ct.TensorType(name=n) for n in outputs],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )


def main():
    sel_args = (torch.randint(5, 1000, (B, L_SEL)), torch.ones(B, L_SEL, dtype=torch.long),
                torch.randn(B, N_DISC))
    sco_args = (torch.randint(5, 1000, (B, L_SCORE)), torch.ones(B, L_SCORE, dtype=torch.long))

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        sel = convert(Selector(), sel_args, ["ids", "mask", "disc"],
                      ["saliency", "start_p", "end_p"])
        sco = convert(Scorer(), sco_args, ["ids", "mask"], ["score"])
        sel.save(str(tmp / "select.mlpackage"))
        sco.save(str(tmp / "score.mlpackage"))

        desc = MultiFunctionDescriptor()
        desc.add_function(str(tmp / "select.mlpackage"), src_function_name="main",
                          target_function_name="select")
        desc.add_function(str(tmp / "score.mlpackage"), src_function_name="main",
                          target_function_name="score")
        # `select` is the default deliberately: the test that matters asserts that loading
        # WITHOUT a function name hands back the selector and has no `score` to give.
        desc.default_function_name = "select"
        merged = tmp / "clips-multifunction.mlpackage"
        save_multifunction(desc, str(merged))

        shutil.rmtree(OUT, ignore_errors=True)
        OUT.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(merged), str(OUT.parent)],
                       check=True, capture_output=True)
        built = OUT.parent / "clips-multifunction.mlmodelc"
        if built != OUT:
            shutil.move(str(built), str(OUT))

    size = sum(f.stat().st_size for f in OUT.rglob("*") if f.is_file())
    print(f"wrote {OUT}  {size/1024:.0f} KB")
    print(f"  select ids/mask [{B},{L_SEL}] disc [{B},{N_DISC}]  ->  saliency/start_p/end_p")
    print(f"  score  ids/mask [{B},{L_SCORE}]                    ->  score")
    if size > 400 * 1024:
        raise SystemExit(f"fixture is {size/1024:.0f} KB; it is meant to be weightless")


if __name__ == "__main__":
    main()
