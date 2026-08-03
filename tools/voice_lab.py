#!/usr/bin/env python3
"""Synthesis and listening plumbing shared by the checking tools.

`say.sh` and `hear.sh` produce audio for *a person* to listen to. The two
checking tools do the same for a *machine* — `proofread.py` hands it to ASR,
`check_reading.py` compares it against reference pronunciations — and all of
them need the same two things: which voice the pet is set to, and how to make it
say something the way the pet would.

The voice comes from the VoxCPM service, the same one `VoxCPMVoice` speaks
through, so a tool and the pet can never disagree about how a line sounds. That
is worth more than it sounds: the engine these replaced was driven by a CLI that
took its sampling parameters from the command line, and `say.sh` passed none of
them — so every line anyone listened to was synthesised at settings the pet
never used.

**Randomness works the other way round here, and it changes how to sample.**
The old engine varied every take by itself, so N repeats gave N different
renderings for free. VoxCPM is deterministic: the same (voice, text, seed) is
byte-for-byte identical audio, and omitting the seed picks a fixed default
rather than a random one. So anything measuring a *rate* has to vary the seed
itself — fifteen takes at one seed is one take counted fifteen times, and would
report every rate as 0% or 100%.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import wave

import numpy as np

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")),
                    "godot", "app_userdata", "Godot Pet")
CONFIG = os.path.join(DATA, "config.cfg")

VOXCPM_URL = os.environ.get("GODOT_PET_VOXCPM_URL", "http://127.0.0.1:8080")
KEY_NAME = "VOXCPM_API_KEY"

# The service asks callers to back off on 503 rather than treating it as a
# failure: it runs a single worker on purpose, because concurrent calls into
# VoxCPM2 corrupt the output silently instead of raising.
RETRIES = 3
RETRY_SECONDS = 1.5

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
ASR_URL = os.environ.get("GODOT_PET_ASR_URL", "http://127.0.0.1:8765")
ASR_RATE = 16000
ASR_START = ("cd ~/git_project/QwenASRMiniTool && .venv/bin/python server.py "
             "--model ./GPUModel/qwen3-asr-1.7b.bin --chatllm-dir ./chatllm --gpu "
             "--host 127.0.0.1 --port 8765")


def _dotenv(name: str) -> str:
    """One key out of the project's `.env`, which is where the app looks last.

    Read here rather than left to the environment because that is where the key
    actually lives on this machine, and a tool that could not find what the pet
    finds would report the service as refusing when it is not.
    """
    try:
        with open(os.path.join(REPO, ".env"), encoding="utf-8") as handle:
            for line in handle:
                key, _, value = line.partition("=")
                if key.strip() == name:
                    return value.strip().strip("'\"")
    except OSError:
        pass
    return ""


def api_key() -> str:
    return os.environ.get(KEY_NAME, "") or _dotenv(KEY_NAME)


def _headers(json_body: bool) -> dict[str, str]:
    out = {"Content-Type": "application/json"} if json_body else {}
    key = api_key()
    if key:
        out["Authorization"] = "Bearer " + key
    return out


def _config(key: str) -> str | None:
    """One key out of config.cfg's [tts] section. Godot writes plain INI here."""
    try:
        with open(CONFIG, encoding="utf-8") as handle:
            body = handle.read()
    except OSError:
        return None
    found = re.search(rf'^{re.escape(key)}="?([^"\n]*)"?$', body, re.MULTILINE)
    return found.group(1) if found else None


def list_voices() -> list[str]:
    try:
        request = urllib.request.Request(f"{VOXCPM_URL}/v1/voices",
                                         headers=_headers(False))
        with urllib.request.urlopen(request, timeout=15) as response:
            return [str(v.get("voice_id", ""))
                    for v in json.load(response).get("voices", [])]
    except (urllib.error.URLError, OSError, ValueError):
        return []


def current_voice() -> str:
    """Whichever voice the pet is set to, or the first the service offers.

    Read every run rather than taken as an argument default, because the user
    changes it in the menu and a stale answer would attribute one voice's
    problems to another.
    """
    chosen = _config("voxcpm_voice") or ""
    known = list_voices()
    if chosen and (not known or chosen in known):
        return chosen
    return known[0] if known else ""


def service_ready() -> tuple[bool, str]:
    """Whether the voice service is usable, and a sentence saying so either way.

    The voice list is checked as well as /health, because /health is exempt from
    the API key: a service with auth switched on answers it happily and then
    refuses everything that matters.
    """
    try:
        with urllib.request.urlopen(f"{VOXCPM_URL}/health", timeout=5) as response:
            body = json.load(response)
    except (urllib.error.URLError, OSError, ValueError) as error:
        return False, (f"連不上語音服務 {VOXCPM_URL}（{error.__class__.__name__}）。\n"
                       f"啟動方式：cd ~/git_project/voxcpm-voice-api && "
                       f"PYTHONPATH=src python -m uvicorn voxcpm_api.server:app "
                       f"--host 127.0.0.1 --port 8080")
    if body.get("status") != "ok":
        return False, f"語音服務還沒準備好（status={body.get('status')}）。"
    if not list_voices():
        return False, (f"語音服務有回應，但拿不到音色清單——多半是 API key 不對。"
                       f"把 {KEY_NAME} 放進 {os.path.join(REPO, '.env')}。")
    return True, f"語音：{VOXCPM_URL}（{body.get('gpu', '?')}）"


def say(text: str, out: str, voice: str | None = None, seed: int | None = None) -> None:
    """Synthesise one line to `out`, the way the pet would say it.

    `seed` omitted means the service's own default, which is fixed rather than
    random — see the note at the top of this file before using that to measure
    anything.
    """
    payload: dict[str, object] = {
        "voice_id": voice or current_voice(),
        "text": text,
        "format": "wav",
    }
    if seed is not None:
        payload["seed"] = seed
    for attempt in range(RETRIES):
        request = urllib.request.Request(f"{VOXCPM_URL}/v1/tts",
                                         data=json.dumps(payload).encode("utf-8"),
                                         headers=_headers(True))
        try:
            with urllib.request.urlopen(request, timeout=190) as response:
                with open(out, "wb") as handle:
                    handle.write(response.read())
            return
        except urllib.error.HTTPError as error:
            # 503 is the queue being full, which the service asks callers to
            # wait out rather than treat as a failure.
            if error.code != 503 or attempt == RETRIES - 1:
                raise
            time.sleep(RETRY_SECONDS * (attempt + 1))


def samples(path: str) -> np.ndarray:
    with wave.open(path) as handle:
        raw = handle.readframes(handle.getnframes())
    return np.frombuffer(raw, dtype=np.int16).astype(np.float64) / 32768.0


def seconds(path: str) -> float:
    with wave.open(path) as handle:
        return handle.getnframes() / handle.getframerate()


def asr_ready() -> tuple[bool, str]:
    """Whether a usable ASR service is up, and a sentence saying so either way.

    Both ASR servers answer /health identically enough to be mistaken for each
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


def main() -> int:
    """Synthesise one line to a file, so the shell tools need no HTTP of their own.

        tools/voice_lab.py "一句話" 輸出.wav [聲音] [seed]

    Prints the voice it used, which is what `say.sh` reports back.
    """
    if len(sys.argv) < 3:
        print("用法: tools/voice_lab.py '要唸的句子' 輸出.wav [聲音] [seed]",
              file=sys.stderr)
        return 1
    ready, message = service_ready()
    if not ready:
        print(message, file=sys.stderr)
        return 1
    voice = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None
    seed = int(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else None
    try:
        say(sys.argv[1], os.path.abspath(sys.argv[2]), voice=voice, seed=seed)
    except (urllib.error.URLError, OSError) as error:
        print(f"合成失敗：{error}", file=sys.stderr)
        return 1
    print(voice or current_voice())
    return 0


if __name__ == "__main__":
    sys.exit(main())
