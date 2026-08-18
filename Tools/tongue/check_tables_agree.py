"""Assert the three ports' generated Unicode tables encode the same data.

    python3 Tools/tongue/check_tables_agree.py

`mise run gen-tables` regenerates all three from the Python reference, and CI
diffs the result — but only when it can check out the reference, which is a
private repo. Without the token that step skips, so for a long time the job could
not fail at all.

This check needs nothing external. It parses the committed tables out of the three
ports and compares them to each other, which catches the failure that actually
matters: one port hand-edited, or one regenerated while the others were not. A
drift that moved all three identically would still need the reference to catch,
and `gen-tables` does that locally.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent

SWIFT = ROOT / "Sources/Tongue/ScriptTables.swift"
KOTLIN = ROOT / "packages/tongue-kotlin/src/main/kotlin/ai/desertant/tongue/ScriptTables.kt"
TS = ROOT / "packages/tongue-node/src/script-tables.ts"


def swift_ranges(text: str) -> list[tuple[int, int, str]]:
    return [
        (int(a, 16), int(b, 16), name)
        for a, b, name in re.findall(r"\(0x([0-9A-Fa-f]+),\s*0x([0-9A-Fa-f]+),\s*\.(\w+)\)", text)
    ]


def kotlin_ranges(text: str) -> list[tuple[int, int, str]]:
    return [
        (int(a, 16), int(b, 16), name)
        for a, b, name in re.findall(
            r"Range\(0x([0-9A-Fa-f]+),\s*0x([0-9A-Fa-f]+),\s*\"(\w+)\"\)", text
        )
    ]


def ts_ranges(text: str) -> list[tuple[int, int, str]]:
    return [
        (int(a, 16), int(b, 16), name)
        for a, b, name in re.findall(r"\[0x([0-9A-Fa-f]+),\s*0x([0-9A-Fa-f]+),\s*\"(\w+)\"\]", text)
    ]


def main() -> int:
    missing = [p for p in (SWIFT, KOTLIN, TS) if not p.exists()]
    if missing:
        for p in missing:
            print(f"error: {p.relative_to(ROOT)} is missing", file=sys.stderr)
        return 1

    ports = {
        "swift": swift_ranges(SWIFT.read_text(encoding="utf-8")),
        "kotlin": kotlin_ranges(KOTLIN.read_text(encoding="utf-8")),
        "js": ts_ranges(TS.read_text(encoding="utf-8")),
    }

    for name, ranges in ports.items():
        if not ranges:
            print(f"error: parsed zero ranges from the {name} table — the format changed, "
                  f"so this check was silently passing", file=sys.stderr)
            return 1

    # Compare case-insensitively on the script name: Swift spells its enum cases
    # lowercase, Kotlin capitalises them, TypeScript uses the reference spelling.
    def key(ranges: list[tuple[int, int, str]]) -> list[tuple[int, int, str]]:
        return sorted((a, b, c.lower()) for a, b, c in ranges)

    reference_name, reference = next(iter(ports.items()))
    reference_key = key(reference)
    ok = True
    for name, ranges in ports.items():
        if name == reference_name:
            continue
        other = key(ranges)
        if other == reference_key:
            continue
        ok = False
        print(f"error: the {name} table does not match the {reference_name} table", file=sys.stderr)
        only_ref = [r for r in reference_key if r not in other]
        only_other = [r for r in other if r not in reference_key]
        for a, b, c in only_ref[:10]:
            print(f"  only in {reference_name}: 0x{a:04X}-0x{b:04X} {c}", file=sys.stderr)
        for a, b, c in only_other[:10]:
            print(f"  only in {name}:  0x{a:04X}-0x{b:04X} {c}", file=sys.stderr)

    if not ok:
        print("\nRun 'mise run gen-tables' to regenerate all three from the reference.", file=sys.stderr)
        return 1

    print(f"  all three ports agree: {len(reference_key)} script ranges")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
