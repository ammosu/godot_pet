#!/usr/bin/env python3
"""Say a line the way the pet would, listen back with ASR, and flag what broke.

    tools/proofread.py "我感覺今天很不錯"      # one line
    tools/proofread.py --nudges                # everything in nudges.json
    tools/proofread.py --nudges -n 3           # fewer takes, faster sweep
    tools/proofread.py -f lines.txt            # one sentence per line

**This is a screen, not a pass mark.** It catches the voice coming apart —
words that came out as different words, sentences that collapsed to one
syllable — and those it catches reliably. It does *not* catch a 破音字 read with
the wrong tone, and the number is worth writing down: 「我發覺事情不對」, where
the 覺 is measurably wrong a third of the time, was transcribed as the correct
characters **15 times out of 15**. The recogniser has a language model, and it
reconstructs the plausible sentence from context no matter which way the
syllable was said. Increasing the takes does not help — that measurement *was*
the increase, from 5 to 15, and the rate stayed at zero.

So: a line this flags is worth listening to. A line it passes has been shown
nothing about, beyond not having fallen apart. For the tone of a single word,
use `check_reading.py`, which never involves a language model at all.

**But this is the one that finds things, and it was nearly not trusted.** It
flagged 「螢幕」 5 times out of 5; `check_reading.py` was then pointed at the
same word, reported it correct 12 times out of 12, and the flag was written off
as noise. The flag was right. Both engines say 「螢幕」 as something else
entirely — 「明木」 on the local model, 「墳墓」 on VoxCPM — and the A/B/X test
missed it because a comparison against two candidate readings cannot see a third.
A user listening to one sample found in seconds what a hundred automated takes
had argued away.

The rule that came out of it: what this flags is a **question**, and the only
thing that closes it is an ear. Never the other tool alone.

Anything flagged keeps its wav, because the point is to shorten the listening
list rather than to replace listening.
"""

from __future__ import annotations

import argparse
import collections
import difflib
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import respell  # noqa: E402
import voice_lab as lab  # noqa: E402

KEEP = os.path.expanduser("~/聽聽看/校對")

# Interjections the recogniser spells its own way. 「欸」 comes back as 「哎」 in
# every single take of every line that contains one, which is the same sound
# written differently rather than the pet saying the wrong thing.
#
# **This only ever changes the order lines are printed in.** Nothing is dropped
# on account of it, because deciding two characters sound alike is exactly the
# judgement `prompts/pronunciation.json` refuses to make without a person — and
# a table like this that is wrong would hide a real defect instead of merely
# ranking it low.
PARTICLES = "欸哎唉誒嗨嘛嗎喔噢唷呦啊呀吧"


def differences(original: str, heard: str) -> list[tuple[str, str]]:
    """Every span where what came back differs from what was written."""
    matcher = difflib.SequenceMatcher(None, original, heard, autojunk=False)
    return [(original[i1:i2], heard[j1:j2])
            for tag, i1, i2, j1, j2 in matcher.get_opcodes() if tag != "equal"]


def interesting(changes: list[tuple[str, str]]) -> bool:
    """Whether any change is more than the recogniser respelling a particle."""
    return any(not (len(was) <= 1 and len(got) <= 1
                    and set(was + got) <= set(PARTICLES))
               for was, got in changes)


def check(original: str, takes: int, rules) -> tuple[str, list[str]]:
    """Say `original` `takes` times and report what came back wrong.

    The comparison is against the **written** line, never the respelled one:
    「感決」 is a spelling trick to make the engine say 「感覺」, so ASR hearing
    「感覺」 is the rule working, and demanding it hear 「感決」 would score
    every correct pronunciation as a failure.
    """
    spoken = respell.respell(original, rules)
    heard = []
    with tempfile.TemporaryDirectory() as scratch:
        for take in range(takes):
            wav = os.path.join(scratch, f"take{take}.wav")
            try:
                lab.say(spoken, wav)
            except subprocess.CalledProcessError as error:
                heard.append(f"（合成失敗：{error.returncode}）")
                continue
            text = lab.transcribe(wav)
            heard.append(text)
            if lab.bare(text) != lab.bare(original):
                os.makedirs(KEEP, exist_ok=True)
                os.replace(wav, os.path.join(
                    KEEP, f"{lab.bare(original)[:12]}-{take + 1}.wav"))
    return spoken, heard


def main() -> int:
    parser = argparse.ArgumentParser(
        description="用語音辨識校對寵物講出來的話，把聽壞的挑出來。")
    parser.add_argument("lines", nargs="*", help="要檢查的句子")
    parser.add_argument("-n", "--takes", type=int, default=5,
                        help="每句合成幾次（預設 5；引擎是隨機的，一次不算數）")
    parser.add_argument("--nudges", action="store_true",
                        help="檢查 prompts/nudges.json 裡所有主動說的話")
    parser.add_argument("-f", "--file", help="從檔案讀，一行一句")
    arguments = parser.parse_args()

    lines = list(arguments.lines)
    if arguments.nudges:
        lines += lab.nudges()
    if arguments.file:
        with open(arguments.file, encoding="utf-8") as handle:
            lines += [line.strip() for line in handle if line.strip()]
    if not lines and not sys.stdin.isatty():
        lines += [line.strip() for line in sys.stdin if line.strip()]
    if not lines:
        parser.print_help()
        return 1

    ready, message = lab.asr_ready()
    print(message)
    if not ready:
        return 1
    if not os.path.isfile(lab.cli()):
        print(f"找不到語音引擎 {lab.cli()}", file=sys.stderr)
        return 1

    tokens, temperature = lab.parameters()
    voice = lab.current_voice()
    print(f"聲音：{voice or '預設嗓音'}　溫度 {temperature}　上限 {tokens} tokens　"
          f"每句 {arguments.takes} 次\n")

    rules = respell.load()
    flagged = []
    for index, original in enumerate(lines, 1):
        spoken, heard = check(original, arguments.takes, rules)
        bare = lab.bare(original)
        changes = collections.Counter()
        real = 0
        for text in heard:
            if lab.bare(text) == bare:
                continue
            spans = differences(bare, lab.bare(text))
            if interesting(spans):
                real += 1
            changes.update(f"{was or '　'}→{got or '　'}" for was, got in spans)
        mark = "！" if real else "　"
        note = "（有替換）" if spoken != original else ""
        print(f"{mark}[{index}/{len(lines)}] {original}{note}　"
              f"{real}/{len(heard)} 次聽到不一樣的音")
        for change, count in changes.most_common(6):
            print(f"      x{count}　{change}")
        if real:
            flagged.append((original, real, len(heard), changes))

    print()
    if not flagged:
        print(f"{len(lines)} 句都沒問題。注意這只代表沒散掉 —— 破音字這個工具是"
              f"看不出來的，請用 tools/check_reading.py。")
        return 0
    print(f"{len(flagged)}/{len(lines)} 句值得聽，音檔留在 {KEEP}：")
    for original, real, takes, changes in sorted(flagged, key=lambda row: -row[1] / row[2]):
        worst = "、".join(change for change, _ in changes.most_common(3))
        print(f"  {real}/{takes}　{original}\n           {worst}")
    print("\n請親耳聽過再決定要不要加規則 —— 辨識錯不等於唸錯。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
