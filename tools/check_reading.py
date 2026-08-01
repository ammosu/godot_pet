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

## How it decides, and why it isn't any of the simpler things

The sentence is synthesised in all three spellings and compared as audio, so no
language model is ever asked what it heard. That matters because the obvious
alternative does not work: ASR transcribed the known-bad 「我發覺事情不對」 as
the correct characters 15 times out of 15, reconstructing the plausible
sentence from context regardless of how the syllable was actually said.

Two acoustic shortcuts were measured and rejected before this one:

- **Duration.** At temperature 0, 發覺/發決 and 銀行/銀航 both came out at
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
at production temperature it is not the same length.

## Why it repeats

The defect is probabilistic, and a single take says nothing. Measured on
「我發覺事情不對」: wrong in 5 takes out of 15 at the temperature the pet
speaks at, and 0 out of 1 at temperature 0, which is greedy decoding and only
ever walks the most likely path. A tool that measured the greedy path would
have reported this word as fine.
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


def spectrogram(path: str) -> np.ndarray:
    audio = lab.samples(path)
    window = np.hanning(WINDOW)
    frames = [np.abs(np.fft.rfft(audio[start:start + WINDOW] * window))
              for start in range(0, max(len(audio) - WINDOW, 0), HOP)]
    return np.log(np.array(frames) + 1e-8) if frames else np.zeros((0, WINDOW // 2 + 1))


def divergence(good: np.ndarray, bad: np.ndarray) -> np.ndarray:
    """The frames where the two references disagree — i.e. where the word is.

    Both are synthesised at temperature 0 from sentences differing in one
    character, so they are the same length and already frame-aligned; the
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
        description="量一個破音字在寵物實際的溫度下有多常唸錯。")
    parser.add_argument("sentence", help="包含那個詞的句子")
    parser.add_argument("word", help="要檢查的詞，例如 發覺")
    parser.add_argument("good", help="只能唸成【對】的讀音的同音寫法，例如 發決")
    parser.add_argument("bad", help="只能唸成【錯】的讀音的同音寫法，例如 發叫")
    parser.add_argument("-n", "--takes", type=int, default=15,
                        help="重複幾次（預設 15；這個引擎隨機到三五次一致毫無意義）")
    # Overriding this answers "would the pet mispronounce it less at another
    # setting", which is the only question the config value cannot answer by
    # itself. The references stay at 0 regardless — they define what the two
    # readings sound like, and that must not move with the thing being measured.
    parser.add_argument("-t", "--temperature", type=float, default=None,
                        help="改用別的溫度（預設讀 config，也就是寵物實際用的）")
    arguments = parser.parse_args()

    if arguments.word not in arguments.sentence:
        print(f"句子裡沒有「{arguments.word}」。", file=sys.stderr)
        return 1
    if not os.path.isfile(lab.cli()):
        print(f"找不到語音引擎 {lab.cli()}", file=sys.stderr)
        return 1

    tokens, configured = lab.parameters()
    temperature = configured if arguments.temperature is None else arguments.temperature
    voice = lab.current_voice()
    print(f"句子：{arguments.sentence}")
    print(f"對照：{arguments.good}（對）／{arguments.bad}（錯）")
    note = "" if arguments.temperature is None else f"（config 是 {configured}）"
    print(f"聲音：{voice or '預設嗓音'}　溫度 {temperature}{note}　上限 {tokens} tokens　"
          f"{arguments.takes} 次\n")

    existing = dict(respell.load()).get(arguments.word)
    if existing:
        print(f"注意：pronunciation.json 已經有「{arguments.word}」→「{existing}」，"
              f"以下量的是【沒有這條規則】時的原始行為。\n")

    with tempfile.TemporaryDirectory() as scratch:
        right = os.path.join(scratch, "good.wav")
        wrong = os.path.join(scratch, "bad.wav")
        try:
            # References at temperature 0 so they are stable and frame-aligned
            # with each other; only the target needs the pet's own randomness.
            lab.say(arguments.sentence.replace(arguments.word, arguments.good),
                    right, temperature=0)
            lab.say(arguments.sentence.replace(arguments.word, arguments.bad),
                    wrong, temperature=0)
        except subprocess.CalledProcessError as error:
            print(f"參照合成失敗：{error.returncode}", file=sys.stderr)
            return 1

        misread = 0
        for take in range(arguments.takes):
            path = os.path.join(scratch, f"take{take}.wav")
            try:
                lab.say(arguments.sentence, path, temperature=temperature)
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
        print(f"這個溫度下沒量到唸錯。要加規則的話，先用 tools/say.sh 親耳確認 —— "
              f"每一條不必要的規則都是一次弄錯的機會。")
    elif existing:
        print(f"規則「{arguments.word}」→「{existing}」擋掉的就是這個。")
    else:
        print(f"值得加一條規則。右邊必須是真正的同音字（含聲調），"
              f"加完用 tools/say.sh 聽一次。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
