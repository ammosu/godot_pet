#!/usr/bin/env python3
"""A resident qwen3-tts.cpp engine the pet can talk to, one sentence at a time.

Why a helper process at all, rather than the CLI or a GDExtension:

* `qwen3-tts-cli` reloads 2.1 GB of model on every invocation — measured at
  754 ms before a single character is synthesized. INTEGRATION.md says plainly
  not to shell out per request, and a pet speaks in short sentences, so the load
  would dominate every line.
* A GDExtension would link the library into Godot itself, which means shipping a
  per-platform binary and taking a crash in the engine's own process. This is a
  *desk pet*; an optional voice must not be able to take the character down.

So: one long-lived process, spoken to in JSON lines. It is deliberately
dependency-free (standard library only, no numpy) because the machine that runs
the pet is not necessarily the machine that built the model.

Protocol, one JSON object per line.

  in   {"op": "say",    "id": 7, "text": "...", "lang": "zh", "voice": "/x.emb"}
       {"op": "clone",  "id": 8, "wav": "/rec.wav", "out": "/voice.emb"}
       {"op": "cancel"}                  drop everything queued but not started
       {"op": "unload"}                  free the model, stay alive
       {"op": "quit"}

  out  {"event": "ready",  "load_ms": 754}
       {"event": "audio",  "id": 7, "path": "...", "rate": 24000, "samples": N}
       {"event": "cloned", "id": 8, "path": "...", "dims": 1024}
       {"event": "error",  "id": 7, "op": "say", "code": "...", "message": "..."}
       {"event": "bye"}

**Every request gets exactly one reply**, including one dropped by a cancel
(`code: "cancelled"`), one with nothing to say (`"empty"`), and a reference clip
with no voice in it (`"silent"`). The caller counts what it is waiting on and
stops polling the response file at zero, so a request answered with silence is
one whose reply is never read — and, if it was the last one, a feature that
half-works in the way least likely to be noticed.

Responses go to the file named by --out, **not** to stdout: the caller redirects
stdout and stderr to a log, because the library and ggml write progress and CUDA
banners to stderr at a rate that would fill an undrained pipe and wedge this
process mid-sentence. The same reasoning as WorkService's stream file, and the
same consequence — the caller tails --out by byte offset and never reads a pipe.
"""

import argparse
import ctypes
import io
import json
import os
import queue
import struct
import sys
import threading
import time
import wave

# From docs/INTEGRATION.md. zh covers Traditional Chinese — the codec has no
# separate id for it, and none for Cantonese either.
LANGUAGE_IDS = {
    "en": 2050, "ru": 2069, "zh": 2055, "ja": 2058, "ko": 2064,
    "de": 2053, "fr": 2061, "es": 2054, "it": 2070, "pt": 2071,
}

EMBEDDING_MAGIC = b"Q3EM"
EMBEDDING_VERSION = 1
## The 0.6B model produces 1024; the buffer only has to be at least that.
MAX_EMBEDDING_DIMS = 4096


def preload(directory):
    """Open the ggml libraries by hand, before the one that needs them.

    The built `libqwen3tts` resolves `libggml*` through an **absolute RUNPATH
    into the tree it was built in**, so a library copied anywhere else cannot
    find them. The usual answer is `LD_LIBRARY_PATH`, and the caller does export
    it — but on macOS dyld strips `DYLD_*` when exec'ing a restricted binary, and
    a system Python is exactly that, so the variable never reaches the loader
    that would use it.

    Loading them here sidesteps the environment entirely: `RTLD_GLOBAL` puts the
    symbols where the next `dlopen` will find them, on every platform, whatever
    the launcher did or did not manage to pass down. Failures are ignored — if
    the RUNPATH was fine all along there is nothing here to open, and if it was
    not, `CDLL(library)` is about to say so far more precisely than this could.
    """
    if not directory or not os.path.isdir(directory):
        return
    for name in sorted(os.listdir(directory)):
        if not name.startswith("libggml"):
            continue
        try:
            ctypes.CDLL(os.path.join(directory, name), mode=ctypes.RTLD_GLOBAL)
        except OSError:
            continue


class Params(ctypes.Structure):
    _fields_ = [
        ("max_audio_tokens", ctypes.c_int32),
        ("temperature", ctypes.c_float),
        ("top_p", ctypes.c_float),
        ("top_k", ctypes.c_int32),
        ("n_threads", ctypes.c_int32),
        ("repetition_penalty", ctypes.c_float),
        ("language_id", ctypes.c_int32),
    ]


class Audio(ctypes.Structure):
    _fields_ = [
        ("samples", ctypes.POINTER(ctypes.c_float)),
        ("n_samples", ctypes.c_int32),
        ("sample_rate", ctypes.c_int32),
    ]


class Engine:
    """The library, loaded lazily and droppable again.

    Lazy because selecting the voice should not cost a second and a gigabyte
    before the pet has anything to say. Droppable because a pet is idle most of
    the day: measured on an RTX 4090, dropping the engine returns 2.6 GB of VRAM
    to the machine the user is also working on, and reloading it costs 750 ms.
    """

    def __init__(self, library, model_dir, threads, lib_path="", max_tokens=0,
                 temperature=0.0):
        self._model_dir = model_dir
        self._threads = threads
        self._max_tokens = max_tokens
        self._temperature = temperature
        self._tts = None
        preload(lib_path)
        lib = ctypes.CDLL(library)
        lib.qwen3_tts_create.restype = ctypes.c_void_p
        lib.qwen3_tts_create.argtypes = [ctypes.c_char_p, ctypes.c_int32]
        lib.qwen3_tts_destroy.argtypes = [ctypes.c_void_p]
        lib.qwen3_tts_default_params.argtypes = [ctypes.POINTER(Params)]
        lib.qwen3_tts_synthesize.restype = ctypes.POINTER(Audio)
        lib.qwen3_tts_synthesize.argtypes = [
            ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(Params)]
        lib.qwen3_tts_synthesize_with_embedding.restype = ctypes.POINTER(Audio)
        lib.qwen3_tts_synthesize_with_embedding.argtypes = [
            ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_float),
            ctypes.c_int32, ctypes.POINTER(Params)]
        lib.qwen3_tts_extract_embedding_file.restype = ctypes.c_int32
        lib.qwen3_tts_extract_embedding_file.argtypes = [
            ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_float),
            ctypes.c_int32]
        lib.qwen3_tts_free_audio.argtypes = [ctypes.POINTER(Audio)]
        lib.qwen3_tts_get_error.restype = ctypes.c_char_p
        lib.qwen3_tts_get_error.argtypes = [ctypes.c_void_p]
        self._lib = lib

    def load(self):
        """Returns milliseconds spent, or raises with a sentence to report."""
        if self._tts is not None:
            return 0
        started = time.time()
        self._tts = self._lib.qwen3_tts_create(self._model_dir.encode(), self._threads)
        if not self._tts:
            self._tts = None
            raise RuntimeError("cannot load models from %s" % self._model_dir)
        return int((time.time() - started) * 1000)

    def unload(self):
        if self._tts is None:
            return
        self._lib.qwen3_tts_destroy(ctypes.c_void_p(self._tts))
        self._tts = None
        # glibc keeps freed arenas mapped, so destroying the engine leaves the
        # host RSS where it was — measured at 290 MB against 236 MB after a trim.
        # The VRAM comes back either way; this is only about not looking like a
        # leak in the user's process list. Best effort, and absent everywhere but
        # glibc, which is why the failure is ignored.
        try:
            ctypes.CDLL("libc.so.6").malloc_trim(0)
        except OSError:
            pass

    def is_loaded(self):
        return self._tts is not None

    def _error(self):
        message = self._lib.qwen3_tts_get_error(ctypes.c_void_p(self._tts))
        return message.decode("utf-8", "replace") if message else "unknown error"

    def synthesize(self, text, language, embedding):
        params = Params()
        self._lib.qwen3_tts_default_params(ctypes.byref(params))
        params.n_threads = self._threads
        params.language_id = LANGUAGE_IDS.get(language, LANGUAGE_IDS["zh"])
        # Generation does not always stop. Measured on one line, same voice,
        # five runs at the library's default temperature of 0.9: one ended
        # normally, one ran to 20.78 s of audio for a six-second sentence, and
        # three died allocating 21598 MiB of VRAM — the graph is sized from the
        # token ceiling, so a run that never emits EOS asks for all of it.
        #
        # The library's own default ceiling is 4096 tokens, which at 12.5 Hz is
        # five and a half minutes. That is the pet reading gibberish aloud for
        # five and a half minutes with every queued sentence stuck behind it,
        # and on a smaller card it is an out-of-memory instead. Neither is a
        # thing a desk pet should be able to do.
        #
        # This does not stop generation running away — see the temperature
        # setting for that — it bounds what happens when it does.
        if self._max_tokens > 0:
            params.max_audio_tokens = self._max_tokens
        # And this is what stops it running away in the first place. Same line,
        # same voice, five runs each: 0.9 (the library's default) ended normally
        # once, 0.7 twice, 0.5 five times out of five, and 0.3 not at all.
        #
        # Both ends fail for opposite reasons — too high and sampling wanders
        # off without ever drawing EOS, too low and greedy decoding never picks
        # it — so this is a value with a floor as well as a ceiling, and 0 is
        # not "use the default" but the worst setting available.
        if self._temperature > 0.0:
            params.temperature = self._temperature
        handle = ctypes.c_void_p(self._tts)
        if embedding:
            buf = (ctypes.c_float * len(embedding))(*embedding)
            audio = self._lib.qwen3_tts_synthesize_with_embedding(
                handle, text.encode(), buf, len(embedding), ctypes.byref(params))
        else:
            audio = self._lib.qwen3_tts_synthesize(
                handle, text.encode(), ctypes.byref(params))
        if not audio:
            raise RuntimeError(self._error())
        try:
            block = audio.contents
            count = block.n_samples
            # Godot's AudioStreamWAV has no float format, so the conversion has to
            # happen somewhere; here is the cheap place for it. Measured at 33 ms
            # for 5.4 seconds of audio, against 1278 ms to generate the same span.
            pcm = bytearray(count * 2)
            struct.pack_into(
                "<%dh" % count, pcm, 0,
                *[int(max(-1.0, min(1.0, block.samples[i])) * 32767)
                  for i in range(count)])
            return bytes(pcm), block.sample_rate, count
        finally:
            self._lib.qwen3_tts_free_audio(audio)

    def extract_embedding(self, wav_path):
        buf = (ctypes.c_float * MAX_EMBEDDING_DIMS)()
        dims = self._lib.qwen3_tts_extract_embedding_file(
            ctypes.c_void_p(self._tts), wav_path.encode(), buf, MAX_EMBEDDING_DIMS)
        if dims < 0:
            raise RuntimeError(self._error())
        return list(buf[:dims])


## Below this a reference clip is a quiet room, not a voice. Measured: a real
## recording of speech peaks around 0.3, and a 13-second capture of an idle
## room — the microphone working, just nobody talking — peaked at 0.023.
SILENT_REFERENCE_PEAK = 0.05

## One second of 48 kHz stereo, so the block stays small whatever the format.
PEAK_BLOCK_FRAMES = 48000


def reference_peak(path):
    """Loudest sample in a WAV, 0..1, or None if this cannot be answered.

    Fails *open* on purpose. The check exists to catch a recording of silence,
    and refusing a voice because the file used some WAV variant `wave` cannot
    parse would be the check causing the failure it is meant to prevent — the
    library itself resamples and downmixes whatever it is given.
    """
    peak = 0
    try:
        with wave.open(path, "rb") as handle:
            if handle.getsampwidth() != 2:
                return None
            # In blocks, never whole. `struct.unpack` builds one Python int per
            # sample — a 5-minute take at the recorder's own 44.1 kHz stereo cap
            # is 53 M samples, which is over a gigabyte of int objects and several
            # seconds of a helper that answers nothing, to compute a maximum that
            # only ever gets compared against 0.05.
            while True:
                frames = handle.readframes(PEAK_BLOCK_FRAMES)
                if not frames:
                    break
                count = len(frames) // 2
                if count:
                    block = struct.unpack("<%dh" % count, frames[:count * 2])
                    # max and -min rather than max(abs(...)): same answer, and it
                    # does not build an abs() per sample.
                    peak = max(peak, max(block), -min(block))
    except (wave.Error, EOFError, OSError):
        return None
    return peak / 32768.0


def read_embedding(path):
    with open(path, "rb") as handle:
        header = handle.read(12)
        if len(header) < 12:
            raise ValueError("%s is too short to be a speaker embedding" % path)
        magic, version, dims = struct.unpack("<4sII", header)
        if magic != EMBEDDING_MAGIC:
            raise ValueError("%s is not a speaker embedding" % path)
        if version != EMBEDDING_VERSION:
            raise ValueError("unsupported embedding version %d" % version)
        body = handle.read(dims * 4)
        if len(body) < dims * 4:
            raise ValueError("%s is truncated" % path)
        return list(struct.unpack("<%df" % dims, body))


def write_embedding(path, values):
    # Written beside the destination and renamed, so a reader can never see a
    # half-written voice — the pet loads this file on startup.
    temporary = path + ".part"
    with open(temporary, "wb") as handle:
        handle.write(struct.pack("<4sII", EMBEDDING_MAGIC, EMBEDDING_VERSION, len(values)))
        handle.write(struct.pack("<%df" % len(values), *values))
    os.replace(temporary, path)


class Responder:
    """One JSON line per event, flushed, so the caller's byte-offset tail sees it."""

    def __init__(self, path):
        self._handle = open(path, "a", encoding="utf-8")

    def send(self, **payload):
        self._handle.write(json.dumps(payload, ensure_ascii=False) + "\n")
        self._handle.flush()


def reader(requests, state):
    """stdin on its own thread, so a `cancel` arriving mid-sentence is seen.

    The library is synchronous and cannot be interrupted, so cancelling never
    stops what is already being generated — it stops everything *behind* it,
    which is the case that matters: interrupting the pet three sentences into a
    reply must not leave it synthesizing the other two.

    **A cancel cannot travel in the queue with the work it cancels.** It arrives
    after that work by definition, so the main loop would pop and synthesize all
    of it first and only then read the cancel, with nothing left to drop —
    measured exactly that way: five sentences queued, cancelled after one, and
    all five were spoken. So the cancel does not go in the queue at all. It
    records the highest id enqueued so far, and the main loop refuses anything at
    or below that mark when it comes to pop it.

    Recording rather than draining keeps every `out.send` on the main thread, so
    the response file needs no lock.
    """
    # Decoded as UTF-8 explicitly rather than by locale. Measured: under
    # `en_US.ISO-8859-1`, `for line in sys.stdin` decodes 「你好」 as mojibake and
    # raises **nothing** — the surrounding JSON is ASCII, so it parses, and the
    # pet then articulates the mojibake. Silent corruption of the words it says
    # is a worse outcome than a crash, and every user-facing string in this
    # project is Traditional Chinese.
    stream = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace")
    try:
        for line in stream:
            line = line.strip()
            if not line:
                continue
            try:
                request = json.loads(line)
            except ValueError:
                continue
            if request.get("op") == "cancel":
                state["cancel_upto"] = state["last_said_id"]
                continue
            if request.get("op") == "say":
                state["last_said_id"] = max(
                    state["last_said_id"], int(request.get("id", 0)))
            requests.put(request)
    finally:
        # The only path by which the main loop can ever be told to stop, so it
        # has to survive anything this thread does. Without the `finally`, a
        # reader that died would leave the process alive with nobody able to end
        # it — and the caller's `OS.kill` is a tidy path, not the guarantee.
        requests.put({"op": "quit"})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lib", required=True)
    parser.add_argument("--models", required=True)
    parser.add_argument("--lib-path", default="",
                        help="directory holding libggml*, preloaded before the engine")
    parser.add_argument("--out", required=True, help="where to write response lines")
    parser.add_argument("--spool", required=True, help="directory for PCM output")
    # Passed because the API takes it, not because it does anything: measured,
    # both the create() argument and the params field are inert upstream — the
    # argument is explicitly discarded and nothing reads the field. Kept so this
    # side is already right if that changes, and documented so nobody spends an
    # afternoon tuning it.
    parser.add_argument("--threads", type=int, default=8)
    parser.add_argument("--idle", type=float, default=300.0,
                        help="seconds of silence before the model is unloaded")
    parser.add_argument("--max-tokens", type=int, default=0,
                        help="ceiling on audio tokens per utterance; 0 leaves "
                             "the library's own default of 4096 (5.5 minutes)")
    parser.add_argument("--temperature", type=float, default=0.0,
                        help="sampling temperature; 0 leaves the library's own "
                             "default of 0.9, which runs away often")
    args = parser.parse_args()

    os.makedirs(args.spool, exist_ok=True)
    out = Responder(args.out)

    try:
        engine = Engine(args.lib, args.models, args.threads, args.lib_path,
                        args.max_tokens, args.temperature)
        load_ms = engine.load()
    except Exception as error:  # OSError from CDLL, RuntimeError from create
        # id 0 and op "load" is what marks this fatal on the caller's side: one
        # sentence failing is survivable, the model not being there is not.
        out.send(event="error", id=0, op="load", message=str(error))
        out.send(event="bye")
        return 1
    out.send(event="ready", load_ms=load_ms)

    requests = queue.Queue()
    # Shared with the reader thread. Ints only, written by one side and read by
    # the other, which under the GIL needs no lock — see reader() for why the
    # cancel has to live out here rather than in the queue.
    state = {"last_said_id": 0, "cancel_upto": 0}
    threading.Thread(target=reader, args=(requests, state), daemon=True).start()

    voices = {}
    last_work = time.time()
    while True:
        try:
            request = requests.get(timeout=5.0)
        except queue.Empty:
            if engine.is_loaded() and time.time() - last_work > args.idle:
                engine.unload()
            continue

        op = request.get("op")
        if op == "quit":
            break
        if op == "unload":
            engine.unload()
            continue
        request_id = int(request.get("id", 0))
        # Only sentences. `say` and `clone` share one id space on the caller's
        # side, so a watermark applied to both would let an ordinary "stop
        # talking" throw away a voice-clone the user asked for a moment earlier —
        # and the failure would read as the recording being at fault.
        if op == "say" and request_id <= state["cancel_upto"]:
            # Answered, not silently binned. The caller counts what it is waiting
            # on and stops polling at zero; a dropped request that never replies
            # would leave it polling for the rest of the session.
            out.send(event="error", id=request_id, op=op, code="cancelled",
                     message="dropped by cancel")
            continue

        last_work = time.time()
        try:
            engine.load()
        except Exception as error:
            out.send(event="error", id=0, op="load", message=str(error))
            continue

        try:
            if op == "say":
                text = str(request.get("text", "")).strip()
                if not text:
                    # Answered rather than dropped. The caller counts requests it
                    # is waiting on and stops polling at zero, so a request that
                    # goes unanswered is one whose reply is never read again.
                    out.send(event="error", id=request_id, op="say",
                             code="empty", message="nothing to say")
                    continue
                voice_path = str(request.get("voice", ""))
                if voice_path and voice_path not in voices:
                    voices[voice_path] = read_embedding(voice_path)
                started = time.time()
                pcm, rate, count = engine.synthesize(
                    text, str(request.get("lang", "zh")), voices.get(voice_path))
                path = os.path.join(args.spool, "%d.pcm" % request_id)
                with open(path + ".part", "wb") as handle:
                    handle.write(pcm)
                os.replace(path + ".part", path)
                out.send(event="audio", id=request_id, path=path, rate=rate,
                         samples=count, ms=int((time.time() - started) * 1000))
            elif op == "clone":
                # A speaker embedding from a silent room is not an error to the
                # library — measured, it returns 1024 perfectly well-formed
                # numbers, and the pet then speaks in an arbitrary voice nobody
                # chose. The only place this is catchable is here, before the
                # extractor is asked a question it cannot decline to answer.
                peak = reference_peak(str(request["wav"]))
                if peak is not None and peak < SILENT_REFERENCE_PEAK:
                    # Coded rather than only worded: the caller has to say
                    # something different about this than about a file it could
                    # not read, and matching on the text of a message would be
                    # matching on wording nobody has agreed to keep.
                    out.send(event="error", id=request_id, op="clone",
                             code="silent",
                             message="reference audio is almost silent "
                                     "(peak %.3f)" % peak)
                    continue
                values = engine.extract_embedding(str(request["wav"]))
                if not values:
                    raise RuntimeError("no speaker embedding came back")
                write_embedding(str(request["out"]), values)
                # A voice file can be replaced in place, so nothing may be cached
                # against a path whose contents just changed.
                voices.pop(str(request["out"]), None)
                out.send(event="cloned", id=request_id, path=str(request["out"]),
                         dims=len(values))
        except Exception as error:
            out.send(event="error", id=request_id, op=op, message=str(error))
        last_work = time.time()

    engine.unload()
    out.send(event="bye")
    return 0


if __name__ == "__main__":
    sys.exit(main())
