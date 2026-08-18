"""Generate src/script-tables.ts from the Python reference.

    python3 Tools/tongue/gen_ts_tables.py --reference ../tongue-training

Generated for the same reason as the Swift and Kotlin tables: the router is a
frozen specification, and hand-copying 47 Unicode ranges into a fourth language
is how ports drift.
"""
import argparse, pathlib, sys

ap = argparse.ArgumentParser()
ap.add_argument("--reference", type=pathlib.Path, default=pathlib.Path("../tongue-training"))
ap.add_argument("--out", type=pathlib.Path, default=pathlib.Path("packages/tongue-node/src/script-tables.ts"))
args = ap.parse_args()

sys.path.insert(0, str((args.reference / "src").resolve()))
import tongue_training.script as S  # noqa: E402

table = None
for name in dir(S):
    value = getattr(S, name)
    if isinstance(value, (list, tuple)) and value and isinstance(value[0], tuple) and len(value[0]) == 3:
        table = value
        break
if table is None:
    raise SystemExit("could not locate the script range table in the reference")

ranges = ",\n  ".join(f'[0x{a:04X}, 0x{b:04X}, "{c}"]' for a, b, c in table)
decisive = ",\n  ".join(f'{k}: "{v}"' for k, v in sorted(S.DECISIVE.items()))
narrowing = ",\n  ".join(
    f'{k}: [{", ".join(chr(34) + x + chr(34) for x in v)}]' for k, v in sorted(S.NARROWING.items())
)

args.out.parent.mkdir(parents=True, exist_ok=True)
args.out.write_text(f'''// UAX#24 script routing, GENERATED from the Python reference by
// Tools/tongue/gen_ts_tables.py. Do not hand-edit: regenerate instead, so the ports
// and the reference cannot drift.

/** Sorted, non-overlapping ranges; looked up by binary search. */
export const RANGES: ReadonlyArray<readonly [number, number, string]> = [
  {ranges},
];

/** Scripts only one language uses: presence settles the answer outright. */
export const DECISIVE: Readonly<Record<string, string>> = {{
  {decisive},
}};

/** Scripts several languages share: presence narrows the candidate set. */
export const NARROWING: Readonly<Record<string, readonly string[]>> = {{
  {narrowing},
}};

/** Reported by the router for the kana special case; owns no range. */
export const JAPANESE = "Japanese";
''')
print(f"wrote {args.out}: {len(table)} ranges, {len(S.DECISIVE)} decisive, {len(S.NARROWING)} narrowing")
