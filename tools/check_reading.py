#!/usr/bin/env python3
"""Ask how often a 破音字 comes out with the wrong reading, without listening.

    tools/check_reading.py 我發覺事情不對 發覺 發決 發叫
    tools/check_reading.py 這個視覺效果很棒 視覺 視決 視叫 -n 15

Four arguments: the sentence, the word in question, a spelling that can only be
read the **right** way, and one that can only be read the **wrong** way. Both
references have to be genuine homophones of the two readings, tone included —
the same discipline `prompts/pronunciation.json` demands of its right-hand
side, and for the same reason: a wrong reference makes the answer wrong with
nothing to show for it.

## What it cannot do, and the false negative that proves it

**It only ever answers "A or B".** Given a word, a right-sounding spelling and a
wrong-sounding one, it says which of those two the engine is closer to — so if
the engine is saying a *third* thing, the wrong reference is far away, the right
one wins by default, and the word is reported as fine.

Measured, on 「螢幕」: this said qwen3 read it correctly, 0 mispronounced out of
12. It does not. Asked to say 「我剛剛數了螢幕上有幾個視窗」 the engine produced
「明木」「根木」「積木」「針目」 — five times out of five, none of them the
「金幕」 the test was comparing against. `proofread.py` had flagged the same word
5/5 and was overruled on the strength of this number.

So the division of labour is the opposite of the obvious one. **ASR finds; this
quantifies.** Reach for this once a person has heard the word and named the two
readings in play — never to clear a word nobody has listened to.

## How it decides, and why it isn't any of the simpler things

The sentence is synthesised in all three spellings and compared as audio, so no
language model is ever asked what it heard. That matters because the obvious
alternative does not work: ASR transcribed the known-bad 「我發覺事情不對」 as
the correct characters 15 times out of 15, reconstructing the plausible
sentence from context regardless of how the syllable was actually said.

Two acoustic shortcuts were measured and rejected before this one:

- **Duration.** Held deterministic, 發覺/發決 and 銀行/銀航 both came out at
  *identical* lengths to six decimal places. One syllable is one syllable
  whichever way it is read.
- **Whole-utterance difference.** The known-same pair (銀行/銀航, which the
  engine already reads háng) differed *more* by waveform RMS than the
  known-different pair — two renderings can differ everywhere and still say the
  same thing. Averaging over the sentence buries the one syllable that matters
  under the several that are shared.

So the comparison is restricted to the frames where the two references differ
from *each other* — which is where the syllable is, located without anyone
having to say where — and the target is aligned onto that window by DTW, since
a take on another seed is not the same length.

## Why it repeats, and why every take gets its own seed

The defect is probabilistic, and a single take says nothing: on the engine this
replaced, 「我發覺事情不對」 came out wrong 5 times in 15 and right the other 10.

**The seed is not a detail here.** VoxCPM is deterministic — the same
(voice, text, seed) is byte-for-byte the same audio, and leaving the seed out
picks a fixed default rather than a random one. So repeating without varying it
is one take counted N times, and every word would score 0/N or N/N with nothing
in between. The references are pinned to one seed for the opposite reason: they
are the ruler, and a ruler that moved with the thing being measured would be
no ruler at all.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import respell  # noqa: E402
import voice_lab as lab  # noqa: E402

WINDOW = 512
HOP = 128

## The references never move: they are what "this reading" and "that reading"
## sound like, and a reference that varied with the thing being measured would
## be a ruler made of the same rubber as the object.
REFERENCE_SEED = 7
## Where the sampled takes start. Fixed so a run can be reproduced exactly.
SEED_BASE = 40000


def spectrogram(path: str) -> np.ndarray:
    audio = lab.samples(path)
    window = np.hanning(WINDOW)
    frames = [np.abs(np.fft.rfft(audio[start:start + WINDOW] * window))
              for start in range(0, max(len(audio) - WINDOW, 0), HOP)]
    return np.log(np.array(frames) + 1e-8) if frames else np.zeros((0, WINDOW // 2 + 1))


def divergence(good: np.ndarray, bad: np.ndarray) -> np.ndarray:
    """The frames where the two references disagree — i.e. where the word is.

    Both are synthesised on one fixed seed from sentences differing in a single
    character, so they are as nearly frame-aligned as two renderings get; the
    frames that stand out are the syllable and nothing else.
    """
    length = min(len(good), len(bad))
    profile = np.mean(np.abs(good[:length] - bad[:length]), axis=1)
    if not len(profile):
        return np.zeros(0, dtype=bool)
    return profile > profile.mean() + profile.std()


def alignment(target: np.ndarray, reference: np.ndarray) -> dict[int, list[int]]:
    """Which target frames each reference frame corresponds to, by DTW."""
    a = target / np.maximum(np.linalg.norm(target, axis=1, keepdims=True), 1e-12)
    b = reference / np.maximum(np.linalg.norm(reference, axis=1, keepdims=True), 1e-12)
    cost = 1.0 - a @ b.T
    total = np.full((len(a) + 1, len(b) + 1), np.inf)
    total[0, 0] = 0.0
    for i in range(1, len(a) + 1):
        for j in range(1, len(b) + 1):
            total[i, j] = cost[i - 1, j - 1] + min(
                total[i - 1, j], total[i, j - 1], total[i - 1, j - 1])
    mapping: dict[int, list[int]] = {}
    i, j = len(a), len(b)
    while i > 0 and j > 0:
        mapping.setdefault(j - 1, []).append(i - 1)
        _, i, j = min((total[i - 1, j], i - 1, j),
                      (total[i, j - 1], i, j - 1),
                      (total[i - 1, j - 1], i - 1, j - 1))
    return mapping


def verdict(target: str, good: str, bad: str) -> tuple[float, float]:
    """Distance from the take to each reference, inside the syllable window."""
    take, right, wrong = spectrogram(target), spectrogram(good), spectrogram(bad)
    window = divergence(right, wrong)
    if not window.any() or not len(take):
        return 0.0, 0.0
    mapping = alignment(take, right)
    to_right = to_wrong = 0.0
    counted = 0
    for frame in np.flatnonzero(window):
        for aligned in mapping.get(int(frame), []):
            to_right += float(np.mean(np.abs(take[aligned] - right[frame])))
            to_wrong += float(np.mean(np.abs(take[aligned] - wrong[frame])))
            counted += 1
    return (to_right / counted, to_wrong / counted) if counted else (0.0, 0.0)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="量一個破音字在寵物實際用的聲音上有多常唸錯。")
    parser.add_argument("sentence", help="包含那個詞的句子")
    parser.add_argument("word", help="要檢查的詞，例如 發覺")
    parser.add_argument("good", help="只能唸成【對】的讀音的同音寫法，例如 發決")
    parser.add_argument("bad", help="只能唸成【錯】的讀音的同音寫法，例如 發叫")
    parser.add_argument("-n", "--takes", type=int, default=15,
                        help="重複幾次（預設 15；三五次一致毫無意義）")
    parser.add_argument("-s", "--seed", type=int, default=SEED_BASE,
                        help="起始 seed；每次 +1，換一組就能重跑一批不同的樣本")
    arguments = parser.parse_args()

    if arguments.word not in arguments.sentence:
        print(f"句子裡沒有「{arguments.word}」。", file=sys.stderr)
        return 1
    speaking, message = lab.service_ready()
    print(message)
    if not speaking:
        return 1
    print(f"句子：{arguments.sentence}")
    print(f"對照：{arguments.good}（對）／{arguments.bad}（錯）")
    print(f"聲音：{lab.current_voice()}　{arguments.takes} 次"
          f"（seed {arguments.seed}–{arguments.seed + arguments.takes - 1}）\n")

    existing = dict(respell.load()).get(arguments.word)
    if existing:
        print(f"注意：pronunciation.json 已經有「{arguments.word}」→「{existing}」，"
              f"以下量的是【沒有這條規則】時的原始行為。\n")

    with tempfile.TemporaryDirectory() as scratch:
        right = os.path.join(scratch, "good.wav")
        wrong = os.path.join(scratch, "bad.wav")
        try:
            # Both references on one fixed seed, so they are stable and as
            # nearly frame-aligned as two one-character-different sentences get;
            # only the targets move, and they move by seed.
            lab.say(arguments.sentence.replace(arguments.word, arguments.good),
                    right, seed=REFERENCE_SEED)
            lab.say(arguments.sentence.replace(arguments.word, arguments.bad),
                    wrong, seed=REFERENCE_SEED)
        except subprocess.CalledProcessError as error:
            print(f"參照合成失敗：{error.returncode}", file=sys.stderr)
            return 1

        misread = 0
        for take in range(arguments.takes):
            path = os.path.join(scratch, f"take{take}.wav")
            try:
                lab.say(arguments.sentence, path, seed=arguments.seed + take)
            except subprocess.CalledProcessError:
                print(f"  {take + 1:2d}. 合成失敗")
                continue
            to_right, to_wrong = verdict(path, right, wrong)
            bad = to_wrong < to_right
            misread += bad
            print(f"  {take + 1:2d}. 距對照(對)={to_right:6.3f}　距對照(錯)={to_wrong:6.3f}"
                  f"　{'<== 唸錯' if bad else '唸對'}")

    rate = misread / max(arguments.takes, 1)
    print(f"\n「{arguments.word}」唸錯 {misread}/{arguments.takes}（{rate:.0%}）")
    if misread == 0:
        print(f"這個聲音上沒量到唸錯。要加規則的話，先用 tools/say.sh 親耳確認 —— "
              f"每一條不必要的規則都是一次弄錯的機會。")
    elif existing:
        print(f"規則「{arguments.word}」→「{existing}」擋掉的就是這個。")
    else:
        print(f"值得加一條規則。右邊必須是真正的同音字（含聲調），"
              f"加完用 tools/say.sh 聽一次。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
