#!/usr/bin/env python3
"""Validate, probe, and fingerprint a native TTS helper artifact."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys


def open_snapshot(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        status = os.fstat(descriptor)
        if not stat.S_ISREG(status.st_mode) or not status.st_mode & 0o111:
            raise SystemExit("helper artifact is not a regular executable")
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(descriptor)
        if (
                after.st_size != status.st_size
                or after.st_mtime_ns != status.st_mtime_ns
                or after.st_ctime_ns != status.st_ctime_ns):
            raise SystemExit("helper artifact changed while hashing")
        return {
            "device": after.st_dev,
            "inode": after.st_ino,
            "size": after.st_size,
            "mode": stat.S_IMODE(after.st_mode),
            "sha256": digest.hexdigest(),
        }
    finally:
        os.close(descriptor)


def probe(path, argument):
    try:
        result = subprocess.run(
            [str(path), argument],
            check=False,
            capture_output=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"helper artifact probe failed: {error}") from None
    if result.returncode != 0 or result.stderr:
        raise SystemExit(f"helper artifact probe failed: {argument}")
    return result.stdout


parser = argparse.ArgumentParser()
parser.add_argument("artifact", type=Path)
parser.add_argument("--engine", required=True)
parser.add_argument("--source-root", type=Path, required=True)
parser.add_argument("--skip-otool", action="store_true")
args = parser.parse_args()

before = open_snapshot(args.artifact)
if probe(args.artifact, "--protocol-version") != b"1\n":
    raise SystemExit("helper artifact protocol version is not exactly 1")
try:
    self_test = json.loads(probe(args.artifact, "--self-test"))
except (UnicodeDecodeError, json.JSONDecodeError):
    raise SystemExit("helper artifact self-test is not valid JSON") from None
if self_test != {"ok": True, "protocol": 1, "engine": args.engine}:
    raise SystemExit("helper artifact self-test identity mismatch")

dependencies = []
otool = shutil.which("otool")
if sys.platform == "darwin" and otool is not None and not args.skip_otool:
    result = subprocess.run(
        [otool, "-L", str(args.artifact)],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode != 0 or result.stderr:
        raise SystemExit("otool dependency inspection failed")
    lines = result.stdout.splitlines()
    if len(lines) < 2:
        raise SystemExit("otool reported no dependency entries")
    dependencies = [
        line.strip().split(" ", 1)[0] for line in lines[1:] if line.strip()
    ]
    if not dependencies:
        raise SystemExit("otool reported no dependency entries")
    source_root = str(args.source_root)
    for dependency in dependencies:
        if dependency == source_root or dependency.startswith(source_root + "/"):
            raise SystemExit(
                "helper artifact dependency points into source checkout"
            )

after = open_snapshot(args.artifact)
if after != before:
    raise SystemExit("helper artifact identity or hash changed during probes")

print(json.dumps({
    "artifact": str(args.artifact),
    **after,
    "protocol": 1,
    "engine": args.engine,
    "dependencies": dependencies,
}, sort_keys=True, separators=(",", ":")))
