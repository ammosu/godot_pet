#!/usr/bin/env python3
"""Propose entries for prompts/pronunciation.json, using a model, offline.

The model belongs *here* and not in the speaking path, and that is measured
rather than assumed. Asked to respell four sentences:

    gpt-5.4-nano   median 1245 ms   turned the text Simplified, and produced
                                    「睡覺」 -> 「歲覺」 — 歲 is suì, not jiào
    gpt-5.4-mini   median  915 ms   correct twice, then produced 「睡覚」 —
                                    覚 is the Japanese form, not a Chinese char

So per sentence it would cost about a second on top of the 0.4-1.3 s the vocoder
already takes, and roughly one line in four would come out *worse* than it went
in, silently, because nothing downstream can tell a good respelling from a bad
one. Run once against a fixed corpus and read by a person before anything is
committed, the same model is useful: it finds candidates far faster than reading
the persona line by line, and every mistake it makes is caught while it is still
a diff.

    export OPENAI_API_KEY=...          # or leave it in the pet's credential store
    tools/build_pronunciation.py                       # scan the pet's own text
    tools/build_pronunciation.py --text "任何一段話"
    tools/build_pronunciation.py --apply               # merge into the json

Nothing is written without --apply, and even then existing entries are never
overwritten — a rule somebody confirmed by ear outranks a fresh guess.
"""

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.request

REPO = pathlib.Path(__file__).resolve().parent.parent
TABLE = REPO / "prompts" / "pronunciation.json"
CORPUS = [REPO / "prompts" / "persona.md", REPO / "prompts" / "nudges.json"]

## mini, not nano: measured above, nano is both slower here and the one that
## switched scripts. Neither is trustworthy enough to skip the review.
MODEL = "gpt-5.4-mini"

SYSTEM = """你在幫一個中文語音合成器做正音。它是端到端模型，沒辦法標拼音，唯一能改發音的方式是把字換掉。

給你一段繁體中文。找出裡面「這個字在這個詞裡不是最常見讀音」的破音字，對每一個提出：
- word：包含它的那個詞（不要只給單字，「行」多數時候是 xíng）
- replacement：把那個字換成讀音完全相同（含聲調）、而且只有一個讀音的字，其餘字不動
- reading：正確讀音的拼音
- why：一句話說明

規則：
- replacement 必須是**繁體中文**常用字。不要簡體字，不要日文漢字。
- 只在你有把握的時候提出。沒把握就不要列。
- 只輸出 JSON 陣列，不要其他文字。"""


def load_key():
    key = os.environ.get("OPENAI_API_KEY", "")
    if key:
        return key
    try:
        out = subprocess.run(
            ["secret-tool", "lookup", "service", "godot-pet", "account", "OPENAI_API_KEY"],
            capture_output=True, text=True, timeout=10)
        if out.returncode == 0:
            return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return ""


def ask(key, text):
    body = {"model": MODEL, "max_completion_tokens": 2000,
            "messages": [{"role": "system", "content": SYSTEM},
                         {"role": "user", "content": text}]}
    request = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=120) as response:
        reply = json.loads(response.read())["choices"][0]["message"]["content"]
    reply = re.sub(r"^```(?:json)?|```$", "", reply.strip(), flags=re.M).strip()
    try:
        found = json.loads(reply)
    except ValueError:
        print("模型的回覆不是 JSON，跳過這一批：", reply[:200], file=sys.stderr)
        return []
    return found if isinstance(found, list) else []


## The two failures measured above are both catchable by looking at the
## characters, which is worth doing even though a person still has to listen: a
## suggestion that is Simplified or Japanese is wrong before anyone hears it.
SIMPLIFIED_ONLY = set("银顺崇书还这样过这来时体开关国东车马华亲爱习见语说话业电点")
JAPANESE_ONLY = set("覚価剣区働駅図県体県桜楽帰気検広鉄読変弁辺")


def suspicious(word, replacement):
    if len(word) != len(replacement):
        return "長度不一樣"
    bad = SIMPLIFIED_ONLY.intersection(replacement)
    if bad:
        return "疑似簡體字：%s" % "".join(sorted(bad))
    bad = JAPANESE_ONLY.intersection(replacement)
    if bad:
        return "疑似日文漢字：%s" % "".join(sorted(bad))
    if word == replacement:
        return "沒有改動"
    changed = sum(1 for a, b in zip(word, replacement) if a != b)
    if changed > 1:
        return "改了 %d 個字，破音字通常只該動一個" % changed
    return ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--text", help="改掃這段文字，而不是寵物自己的台詞")
    parser.add_argument("--apply", action="store_true", help="把乾淨的建議併進 json")
    args = parser.parse_args()

    key = load_key()
    if not key:
        print("找不到 OPENAI_API_KEY（環境變數或 credential store 都沒有）", file=sys.stderr)
        return 1

    if args.text:
        chunks = [args.text]
    else:
        chunks = []
        for path in CORPUS:
            if path.exists():
                body = path.read_text(encoding="utf-8")
                # Whole files at once would blow the context and bury the model in
                # markup; 1500 characters is a few screens of prose.
                chunks += [body[i:i + 1500] for i in range(0, len(body), 1500)]
        print("掃 %d 段（%s）" % (len(chunks), "、".join(p.name for p in CORPUS if p.exists())))

    table = json.loads(TABLE.read_text(encoding="utf-8")) if TABLE.exists() else {}
    existing = table.setdefault("replacements", {})

    accepted, rejected = {}, []
    for i, chunk in enumerate(chunks, 1):
        for item in ask(key, chunk):
            if not isinstance(item, dict):
                continue
            word = str(item.get("word", "")).strip()
            replacement = str(item.get("replacement", "")).strip()
            if not word or not replacement:
                continue
            if word in existing or word in accepted:
                continue
            problem = suspicious(word, replacement)
            if problem:
                rejected.append((word, replacement, problem))
                continue
            accepted[word] = {"replacement": replacement,
                              "reading": str(item.get("reading", "")),
                              "why": str(item.get("why", ""))}
        print("  %d/%d" % (i, len(chunks)), end="\r", flush=True)
    print()

    if rejected:
        print("\n擋下來的（沒有進表）：")
        for word, replacement, problem in rejected:
            print("  %s → %s   %s" % (word, replacement, problem))

    if not accepted:
        print("\n沒有新的建議。")
        return 0

    print("\n建議（**每一條都要用 tools/say.sh 聽過再留**）：")
    for word, item in accepted.items():
        print("  %s → %s   %s   %s"
              % (word, item["replacement"], item["reading"], item["why"]))

    if not args.apply:
        print("\n（沒有寫檔。確定要併進去就加 --apply）")
        return 0

    for word, item in accepted.items():
        existing[word] = item["replacement"]
    TABLE.write_text(json.dumps(table, ensure_ascii=False, indent=2) + "\n",
                     encoding="utf-8")
    print("\n寫進 %s，共 %d 條。重開寵物生效。" % (TABLE, len(existing)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
