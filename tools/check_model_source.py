#!/usr/bin/env python3
"""Check that a GGUF file will actually load into qwen3-tts.cpp.

Run this before changing any URL in `tts/model_fetcher.gd`. The filename proves
nothing: several independent GGUF conversions of Qwen3-TTS exist, they are all
called something plausible, and they do not agree on tensor names. One of them
(`cstr/*`, converted for CrispASR) differs on 109 of the talker's 478 tensors
and on every one of the tokenizer's 448 — it downloads perfectly and fails to
load.

What is compared is what `src/gguf_loader.cpp` actually looks up: the
architecture string, every tensor name, and every tensor shape. A candidate that
matches on all three loads; one that doesn't, doesn't.

Works on local files and on URLs. For a URL only the header is fetched over HTTP
Range — a few MB rather than the 1.3 GB file — because everything compared here
lives in front of the tensor data.

    # against the reference you already have working
    ./tools/check_model_source.py --reference ~/models/qwen3-tts-0.6b-f16.gguf \\
        https://huggingface.co/khimaros/.../Qwen3-TTS-12Hz-0.6B-Base-Q8_0.gguf

    # just describe one
    ./tools/check_model_source.py --show some-model.gguf

Exit status is 0 only when every candidate is compatible, so this can gate a
change rather than merely inform one.
"""

from __future__ import annotations

import argparse
import struct
import sys
import urllib.request

# How much of a remote file to pull. The tokenizer's metadata carries a 151936
# entry vocabulary, which is the largest header here at roughly 4 MB; 16 MB
# leaves room without being a download anyone waits for.
HEADER_BYTES = 16 << 20

# GGUF metadata value types.
(UINT8, INT8, UINT16, INT16, UINT32, INT32, FLOAT32, BOOL, STRING, ARRAY,
 UINT64, INT64, FLOAT64) = range(13)

FIXED = {
    UINT8: ("<B", 1), INT8: ("<b", 1), UINT16: ("<H", 2), INT16: ("<h", 2),
    UINT32: ("<I", 4), INT32: ("<i", 4), FLOAT32: ("<f", 4), BOOL: ("<?", 1),
    UINT64: ("<Q", 8), INT64: ("<q", 8), FLOAT64: ("<d", 8),
}

# ggml_type values that appear in these files, for the quantisation summary.
GGML_TYPES = {0: "F32", 1: "F16", 8: "Q8_0", 12: "Q4_K", 14: "Q6_K"}


class Truncated(Exception):
    """The header ran past the bytes we fetched."""


class Reader:
    def __init__(self, buf: bytes):
        self.buf = buf
        self.pos = 0

    def take(self, n: int) -> bytes:
        if self.pos + n > len(self.buf):
            raise Truncated(f"needed {n} bytes at {self.pos}, have {len(self.buf)}")
        out = self.buf[self.pos:self.pos + n]
        self.pos += n
        return out

    def u32(self) -> int:
        return struct.unpack("<I", self.take(4))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self.take(8))[0]

    def string(self) -> str:
        return self.take(self.u64()).decode("utf-8", "replace")

    def value(self, vtype: int):
        if vtype in FIXED:
            fmt, size = FIXED[vtype]
            return struct.unpack(fmt, self.take(size))[0]
        if vtype == STRING:
            return self.string()
        if vtype == ARRAY:
            etype, count = self.u32(), self.u64()
            if etype == STRING:
                return [self.string() for _ in range(count)]
            if etype in FIXED:
                fmt, size = FIXED[etype]
                return [struct.unpack(fmt, self.take(size))[0] for _ in range(count)]
            raise ValueError(f"unsupported array element type {etype}")
        raise ValueError(f"unsupported value type {vtype}")


class Model:
    def __init__(self, source: str, arch: str, tensors: dict, types: dict):
        self.source = source
        self.arch = arch
        self.tensors = tensors      # name -> dims
        self.types = types          # name -> ggml_type


def parse(buf: bytes, source: str) -> Model:
    r = Reader(buf)
    if r.take(4) != b"GGUF":
        raise ValueError("not a GGUF file (bad magic)")
    r.u32()                          # version
    n_tensors = r.u64()
    n_kv = r.u64()

    arch = ""
    for _ in range(n_kv):
        key = r.string()
        val = r.value(r.u32())
        if key == "general.architecture":
            arch = val if isinstance(val, str) else str(val)

    tensors, types = {}, {}
    for _ in range(n_tensors):
        name = r.string()
        dims = [r.u64() for _ in range(r.u32())]
        types[name] = r.u32()
        r.u64()                      # data offset
        tensors[name] = dims
    return Model(source, arch, tensors, types)


def fetch(source: str) -> bytes:
    if source.startswith(("http://", "https://")):
        request = urllib.request.Request(
            source, headers={"Range": f"bytes=0-{HEADER_BYTES - 1}"})
        with urllib.request.urlopen(request) as response:
            return response.read()
    with open(source, "rb") as handle:
        return handle.read(HEADER_BYTES)


def load(source: str) -> Model:
    return parse(fetch(source), source)


def describe(model: Model) -> None:
    counts: dict[str, int] = {}
    for t in model.types.values():
        name = GGML_TYPES.get(t, f"type{t}")
        counts[name] = counts.get(name, 0) + 1
    spread = "  ".join(f"{k}={v}" for k, v in sorted(counts.items()))
    print(f"  architecture : {model.arch}")
    print(f"  tensors      : {len(model.tensors)}")
    print(f"  quantisation : {spread}")


def compare(reference: Model, candidate: Model) -> bool:
    problems = []
    if candidate.arch != reference.arch:
        problems.append(
            f"architecture is {candidate.arch!r}, loader wants {reference.arch!r}")

    missing = sorted(set(reference.tensors) - set(candidate.tensors))
    extra = sorted(set(candidate.tensors) - set(reference.tensors))
    shapes = [n for n in set(reference.tensors) & set(candidate.tensors)
              if reference.tensors[n] != candidate.tensors[n]]

    if missing:
        problems.append(f"{len(missing)} tensor(s) the loader needs are absent, "
                        f"e.g. {missing[:3]}")
    if extra:
        problems.append(f"{len(extra)} tensor(s) under different names, "
                        f"e.g. {extra[:3]}")
    for n in sorted(shapes)[:3]:
        problems.append(f"shape of {n}: {reference.tensors[n]} != {candidate.tensors[n]}")

    describe(candidate)
    if problems:
        print("  ==> INCOMPATIBLE")
        for p in problems:
            print(f"      - {p}")
        return False
    print("  ==> COMPATIBLE (architecture, all tensor names, all shapes match)")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("candidates", nargs="+", help="GGUF file paths or URLs")
    parser.add_argument("--reference", "-r",
                        help="a GGUF known to load; required unless --show")
    parser.add_argument("--show", action="store_true",
                        help="just describe each candidate, don't compare")
    args = parser.parse_args()

    if not args.show and not args.reference:
        parser.error("need --reference to compare against, or --show to only describe")

    reference = None
    if args.reference:
        try:
            reference = load(args.reference)
        except (OSError, ValueError, Truncated) as e:
            print(f"reference {args.reference}: {e}", file=sys.stderr)
            return 2
        print(f"REFERENCE {args.reference}")
        describe(reference)
        print()

    ok = True
    for source in args.candidates:
        print(source)
        try:
            model = load(source)
        except Truncated as e:
            print(f"  ==> header longer than the {HEADER_BYTES >> 20} MB fetched ({e})")
            print("      raise HEADER_BYTES and retry")
            ok = False
            continue
        except (OSError, ValueError) as e:
            print(f"  ==> could not read: {e}")
            ok = False
            continue
        if args.show or reference is None:
            describe(model)
        elif not compare(reference, model):
            ok = False
        print()

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
