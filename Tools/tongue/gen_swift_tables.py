"""Generate Sources/Tongue/ScriptTables.swift from the Python reference.

Run from the SDK root with the training repo alongside:
    python3 Tools/tongue/gen_swift_tables.py --reference ../tongue-training

The tables are generated rather than transcribed so the SDK and the reference
cannot drift by hand-editing. `Japanese` is included as a pseudo-script: it owns
no Unicode range, but `route` reports it for the kana special case, and the
golden vectors assert that name.
"""
import argparse, pathlib, sys

ap = argparse.ArgumentParser()
ap.add_argument("--reference", type=pathlib.Path, default=pathlib.Path("../tongue-training"))
ap.add_argument("--out", type=pathlib.Path, default=pathlib.Path("Sources/Tongue/ScriptTables.swift"))
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

PSEUDO = ["Japanese"]  # reported by route(), owns no range
scripts = sorted({c for _, _, c in table} | set(S.DECISIVE) | set(S.NARROWING) | set(PSEUDO))

ranges = ",\n        ".join(f"(0x{a:04X}, 0x{b:04X}, .{c.lower()})" for a, b, c in table)
cases = "\n    ".join(f"case {s.lower()} = \"{s}\"" for s in scripts)
decisive = ",\n        ".join(f'.{k.lower()}: "{v}"' for k, v in sorted(S.DECISIVE.items()))
narrowing = ",\n        ".join(
    f'.{k.lower()}: [{", ".join(chr(34) + x + chr(34) for x in v)}]' for k, v in sorted(S.NARROWING.items())
)

args.out.write_text(f'''import Foundation

// UAX#24 script routing, GENERATED from the Python reference by
// Tools/tongue/gen_swift_tables.py. Do not hand-edit: regenerate instead, so the SDK
// and the reference cannot drift.

public enum Script: String, Sendable, CaseIterable {{
    {cases}
}}

enum ScriptTables {{
    // Sorted, non-overlapping ranges; looked up by binary search.
    static let ranges: [(UInt32, UInt32, Script)] = [
        {ranges},
    ]

    // Scripts only one language uses: presence settles the answer outright.
    static let decisive: [Script: String] = [
        {decisive},
    ]

    // Scripts several languages share: presence narrows the candidate set.
    static let narrowing: [Script: [String]] = [
        {narrowing},
    ]
}}
''')
print(f"wrote {args.out}: {len(table)} ranges, {len(scripts)} scripts, "
      f"{len(S.DECISIVE)} decisive, {len(S.NARROWING)} narrowing")
