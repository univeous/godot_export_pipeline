#!/usr/bin/env python3
"""Writes the common-character sets FontSubset can keep (sets/*.txt), which Godot cannot decode itself:
    python3 -I addons/export_pipeline/fonts/make_sets.py
  gb2312_1.txt -- GB2312 level 1, the 3755 common hanzi (rows 16-55, EUC-CN 0xB0A1-0xD7FE)
  jis_1.txt    -- JIS X 0208 level 1, the 2965 common kanji (rows 16-47, EUC-JP 0xB0A1-0xCFFE)
Each file is the characters in code-point order, UTF-8, no newline. Python's own codecs decode them; the counts are
checked (exit 1 otherwise)."""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent / "sets"


def rows(codec: str, first: int, last: int) -> str:
    out = set()
    for hi in range(first, last + 1):
        for lo in range(0xA1, 0xFF):
            try:
                out.add(bytes([hi, lo]).decode(codec))
            except UnicodeDecodeError:
                pass
    return "".join(sorted(out))


def main() -> int:
    HERE.mkdir(exist_ok=True)
    sets = {"gb2312_1": (rows("gb2312", 0xB0, 0xD7), 3755), "jis_1": (rows("euc_jp", 0xB0, 0xCF), 2965)}
    bad = 0
    for name, (chars, want) in sets.items():
        (HERE / f"{name}.txt").write_text(chars, encoding="utf-8")
        print(f"{name}: {len(chars)} characters (want {want})")
        bad |= len(chars) != want
    return bad


if __name__ == "__main__":
    sys.exit(main())
