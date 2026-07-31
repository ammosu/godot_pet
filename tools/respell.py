#!/usr/bin/env python3
"""Apply prompts/pronunciation.json the way TTSService does, and nothing else.

The single place the substitution is implemented outside the app. `say.sh` and
`hear.sh` both call this rather than each carrying their own copy, because a
listening tool that substitutes differently from the pet is worse than no tool:
it would send you looking for a rule that is already right, or pass one that is
already wrong.

Mirrors `TTSService._respell()` exactly — longest key first, plain string
replace, applied in one pass. Keep it that way.

    tools/respell.py "今天感覺不錯欸。"        # prints the spoken form
    tools/respell.py --verbose "…"            # prints written/spoken/which rules
    echo "…" | tools/respell.py               # reads stdin when given no text
"""

from __future__ import annotations

import json
import os
import sys

TABLE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "..", "prompts", "pronunciation.json")


def load(path: str = TABLE) -> list[tuple[str, str]]:
    """The table as [(from, to), …], longest key first.

    A missing or broken file is not an error: the app treats an unreadable table
    as "no substitutions" and carries on speaking, and a tool that refused here
    would report a problem the pet does not have.
    """
    try:
        with open(path, encoding="utf-8") as handle:
            raw = json.load(handle).get("replacements", {})
    except (OSError, ValueError):
        return []
    return [(k, str(v)) for k, v in sorted(raw.items(), key=lambda kv: len(kv[0]),
                                           reverse=True)]


def respell(line: str, rules: list[tuple[str, str]] | None = None) -> str:
    for src, dst in (load() if rules is None else rules):
        line = line.replace(src, dst)
    return line


def fired(line: str, rules: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """Which rules actually matched, in application order."""
    hits, working = [], line
    for src, dst in rules:
        if src in working:
            hits.append((src, dst))
            working = working.replace(src, dst)
    return hits


def main() -> int:
    args = [a for a in sys.argv[1:] if a not in ("--verbose", "-v")]
    verbose = len(args) != len(sys.argv[1:])

    text = args[0] if args else sys.stdin.read().strip()
    if not text:
        print("用法: tools/respell.py '要檢查的句子' [--verbose]", file=sys.stderr)
        return 1

    rules = load()
    spoken = respell(text, rules)
    if not verbose:
        print(spoken)
        return 0

    hits = fired(text, rules)
    print(f"寫的：{text}")
    print(f"唸的：{spoken}" + ("" if hits else "（沒有規則命中）"))
    for src, dst in hits:
        print(f"  ・{src} → {dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
