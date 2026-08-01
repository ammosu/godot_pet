#!/usr/bin/env python3
"""Synthesis and listening plumbing shared by the two checking tools.

`say.sh` and `hear.sh` produce audio for *a person* to listen to. These two do
the same for a *machine* — `proofread.py` hands it to ASR, `check_reading.py`
compares it against reference pronunciations — and both need the same three
things: where the engine is, which voice the pet is using, and what sampling
parameters it speaks with.

**The parameters are the reason this file exists.** `say.sh` and `hear.sh` pass
neither `--temperature` nor `--max-tokens`, so they synthesise at the library's
defaults of 0.9 and 4096 while the pet runs 0.5 and 512 (`Qwen3Voice`'s
constants, since `config.cfg` normally overrides neither). A checking tool that
listened at a different temperature from the one the pet speaks at would be
measuring a voice nobody hears — and temperature is not a detail here: measured
on 「我發覺事情不對」, the 覺 comes out wrong 5 times in 15 at 0.5 and never at
all at 0, because 0 is greedy decoding and only ever walks one path.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import urllib.error
import urllib.request
import wave

import numpy as np

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")),
                    "godot", "app_userdata", "Godot Pet")
VOICES = os.path.join(DATA, "qwen3_tts", "voices")
CONFIG = os.path.join(DATA, "config.cfg")

# Mirrors Qwen3Voice.MAX_AUDIO_TOKENS / DEFAULT_TEMPERATURE. Duplicated here
# rather than parsed out of the GDScript because a checking tool that silently
# stopped matching the app would be worse than one that is visibly a copy —
# and `config.cfg` overrides both anyway, which is the path that actually
# matters on a machine where someone has tuned them.
MAX_TOKENS = 512
TEMPERATURE = 0.5

# QwenASRMiniTool's `server.py`, which exposes /api/transcribe — raw float32 in,
# text out, no segmentation.
#
# **It has to be that one, not `asr_server.py`.** The other server is often
# already running on 8766, and pointing this at it looks like it works: its
# /api/transcribe_file runs silero VAD grouping written for recordings of
# meetings, and on a two-second line it returns the *beginning* of the sentence.
# Measured on one file, through both: 「今天天氣真好。」 raw, 「今天天。」 through
# the VAD path — and padding the clip with up to two seconds of silence on each
# side changed nothing. Batching five lines into one 15-second file was worse
# still: VAD merged them into two groups and cut inside both.
#
# There is deliberately no fallback to it. A truncated transcript reads exactly
# like the pet swallowing the end of its own sentence, which is the one thing
# this tool must never invent.
#
# Nothing here starts the server: it holds a 1.7B model on the GPU, and a
# checking tool that quietly took VRAM from the pet would be a poor trade.
ASR_URL = os.environ.get("GODOT_PET_ASR_URL", "http://127.0.0.1:8765")
ASR_RATE = 16000
ASR_START = ("cd ~/git_project/QwenASRMiniTool && .venv/bin/python server.py "
             "--model ./GPUModel/qwen3-asr-1.7b.bin --chatllm-dir ./chatllm --gpu "
             "--host 127.0.0.1 --port 8765")


def library() -> str:
    return os.environ.get("GODOT_PET_QWEN3_LIB",
                          os.path.expanduser("~/git_project/qwen3-tts.cpp/build/libqwen3tts.so"))


def models() -> str:
    return os.environ.get("GODOT_PET_QWEN3_MODELS",
                          os.path.expanduser("~/git_project/qwen3-tts.cpp/models"))


def cli() -> str:
    return os.path.join(os.path.dirname(library()), "qwen3-tts-cli")


def _config(key: str) -> str | None:
    """One key out of config.cfg's [tts] section. Godot writes plain INI here."""
    try:
        with open(CONFIG, encoding="utf-8") as handle:
            body = handle.read()
    except OSError:
        return None
    found = re.search(rf'^{re.escape(key)}="?([^"\n]*)"?$', body, re.MULTILINE)
    return found.group(1) if found else None


def current_voice() -> str | None:
    """Whichever voice the pet is set to, or None for the model's own.

    Read every run rather than taken as an argument default, because the user
    changes it in the menu and a stale answer would attribute one voice's
    problems to another.
    """
    name = _config("qwen3_voice")
    return name if name and os.path.isfile(os.path.join(VOICES, f"{name}.emb")) else None


def parameters() -> tuple[int, float]:
    max_tokens = _config("qwen3_max_tokens")
    temperature = _config("qwen3_temperature")
    return (int(max_tokens) if max_tokens else MAX_TOKENS,
            float(temperature) if temperature else TEMPERATURE)


def say(text: str, out: str, voice: str | None = None,
        temperature: float | None = None, max_tokens: int | None = None) -> None:
    """Synthesise one line to `out`, the way the pet would say it.

    `out` must be absolute: the CLI resolves a relative path against its own
    working directory, which is the engine tree — measured, by finding the wav
    files there afterwards.
    """
    if not os.path.isabs(out):
        raise ValueError("say() needs an absolute output path")
    default_tokens, default_temperature = parameters()
    command = [cli(), "-m", models(), "-l", "zh", "-t", text,
               "--temperature", str(default_temperature if temperature is None else temperature),
               "--max-tokens", str(default_tokens if max_tokens is None else max_tokens),
               "-o", out]
    name = current_voice() if voice is None else voice
    if name:
        embedding = os.path.join(VOICES, f"{name}.emb")
        if os.path.isfile(embedding):
            command[3:3] = ["--load-embedding", embedding]
    subprocess.run(command, capture_output=True, check=True, cwd=os.path.dirname(models()))


def samples(path: str) -> np.ndarray:
    with wave.open(path) as handle:
        raw = handle.readframes(handle.getnframes())
    return np.frombuffer(raw, dtype=np.int16).astype(np.float64) / 32768.0


def seconds(path: str) -> float:
    with wave.open(path) as handle:
        return handle.getnframes() / handle.getframerate()


def asr_ready() -> tuple[bool, str]:
    """Whether a usable ASR service is up, and a sentence saying so either way.

    Both servers answer /health identically enough to be mistaken for each
    other, so this probes the endpoint that actually matters. Under 100 ms of
    audio is answered with an empty string before the model is touched, which
    makes it a capability check that costs nothing — and a 404 from the wrong
    server is caught here rather than becoming a page of truncated sentences.
    """
    try:
        with urllib.request.urlopen(f"{ASR_URL}/health", timeout=5) as response:
            json.load(response)
        probe = urllib.request.Request(
            f"{ASR_URL}/api/transcribe?language=zh",
            data=np.zeros(160, dtype=np.float32).tobytes(),
            headers={"Content-Type": "application/octet-stream"})
        with urllib.request.urlopen(probe, timeout=30) as response:
            json.load(response)
    except urllib.error.HTTPError as error:
        return False, (f"{ASR_URL} 有服務，但沒有 /api/transcribe（HTTP {error.code}）。"
                       f"多半是 asr_server.py —— 它的檔案端點會把短句截斷。\n"
                       f"請改跑：{ASR_START}")
    except (urllib.error.URLError, OSError, ValueError) as error:
        return False, (f"連不上語音辨識服務 {ASR_URL}（{error.__class__.__name__}）。\n"
                       f"啟動方式：{ASR_START}")
    return True, f"語音辨識：{ASR_URL}"


def transcribe(path: str, language: str = "zh") -> str:
    """What the ASR hears in a wav.

    **`context` is deliberately never sent.** The service accepts a reference
    text to bias recognition towards, which is exactly what a proofreader must
    not do: told what it is supposed to hear, it would agree, and every line
    would come back clean.
    """
    pcm = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-ar", str(ASR_RATE), "-ac", "1",
         "-f", "f32le", "-"], capture_output=True, check=True).stdout
    request = urllib.request.Request(
        f"{ASR_URL}/api/transcribe?language={language}",
        data=pcm, headers={"Content-Type": "application/octet-stream"})
    with urllib.request.urlopen(request, timeout=300) as response:
        return json.load(response).get("text", "")


def bare(text: str) -> str:
    """Text with punctuation and spacing dropped, for comparing against ASR.

    The recogniser punctuates on its own — 「不知不覺就天亮了」 comes back as
    「不知不覺，就天亮了」 — and a comma it invented is not a mispronunciation.
    """
    return re.sub(r"[，。！？、,.!?…\s　]", "", text)


def nudges() -> list[str]:
    """Every line the pet says unprompted, which is what it says most often."""
    try:
        with open(os.path.join(REPO, "prompts", "nudges.json"), encoding="utf-8") as handle:
            pools = json.load(handle)
    except (OSError, ValueError):
        return []
    lines = []
    for name, pool in pools.items():
        if name.startswith("_") or not isinstance(pool, list):
            continue
        for entry in pool:
            text = entry.get("text", "") if isinstance(entry, dict) else str(entry)
            # `memory` entries are {fact} templates filled at pick time, so the
            # raw string is not a sentence anyone hears.
            if text and "{" not in text:
                lines.append(text)
    return lines
