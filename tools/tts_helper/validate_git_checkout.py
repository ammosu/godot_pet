#!/usr/bin/env python3
"""Validate a checkout without invoking attributes, filters, or status."""

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess


def safe_git(repo, *args):
    environment = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": os.environ.get("TMPDIR", "/tmp"),
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
    }
    return subprocess.run(
        [
            shutil.which("git"), "-c", "core.hooksPath=/dev/null",
            "-c", "core.fsmonitor=false", "-C", str(repo), *args,
        ],
        env=environment, check=True, capture_output=True,
    ).stdout


parser = argparse.ArgumentParser()
parser.add_argument("repository", type=Path)
parser.add_argument("commit")
parser.add_argument("--qwen-gitlink")
args = parser.parse_args()

safe_git(
    args.repository, "fsck", "--strict", "--no-dangling", args.commit
)
object_format = safe_git(
    args.repository, "rev-parse", "--show-object-format"
).decode("ascii").strip()
if object_format not in ("sha1", "sha256"):
    raise SystemExit(f"unsupported Git object format: {object_format}")


def verified_blob(oid):
    data = safe_git(args.repository, "cat-file", "blob", oid)
    digest = hashlib.new(object_format)
    digest.update(f"blob {len(data)}\0".encode("ascii"))
    digest.update(data)
    if digest.hexdigest() != oid:
        raise SystemExit(f"Git blob object ID mismatch: {oid}")
    return data


tree = {}
gitlinks = []
for record in safe_git(args.repository, "ls-tree", "-rz", args.commit).split(b"\0"):
    if not record:
        continue
    metadata, raw_path = record.split(b"\t", 1)
    mode, kind, oid = metadata.split(b" ", 2)
    path = os.fsdecode(raw_path)
    if mode == b"160000" and kind == b"commit":
        if path == "ggml" and oid.decode() == args.qwen_gitlink:
            gitlinks.append(oid.decode())
            continue
        raise SystemExit("unexpected gitlink in checkout tree")
    if mode not in (b"100644", b"100755") or kind != b"blob":
        raise SystemExit(f"unsupported checkout tree entry: {path}")
    tree[path] = (mode, oid.decode())
if args.qwen_gitlink is not None and gitlinks != [args.qwen_gitlink]:
    raise SystemExit("missing exact ggml gitlink")

index = {}
for record in safe_git(args.repository, "ls-files", "--stage", "-z").split(b"\0"):
    if not record:
        continue
    metadata, raw_path = record.split(b"\t", 1)
    mode, oid, stage = metadata.split(b" ", 2)
    path = os.fsdecode(raw_path)
    if path == "ggml" and mode == b"160000" and args.qwen_gitlink == oid.decode():
        continue
    if stage != b"0":
        raise SystemExit("checkout index contains a non-zero stage")
    index[path] = (mode, oid.decode())
if index != tree:
    raise SystemExit("checkout index differs from audited tree")

actual = {}
for root, directories, files in os.walk(args.repository, topdown=True, followlinks=False):
    relative_root = Path(root).relative_to(args.repository)
    directories[:] = [
        name for name in directories
        if not (relative_root == Path(".") and name in (".git", "ggml")
                and (name == ".git" or args.qwen_gitlink is not None))
    ]
    for name in list(directories):
        path = Path(root, name)
        if path.is_symlink():
            raise SystemExit(f"symbolic link in checkout: {path}")
    for name in files:
        path = Path(root, name)
        relative = path.relative_to(args.repository).as_posix()
        status = os.lstat(path)
        if not stat.S_ISREG(status.st_mode):
            raise SystemExit(f"non-regular checkout entry: {relative}")
        actual[relative] = path
if set(actual) != set(tree):
    raise SystemExit("checkout has missing or extra files")
for path, (mode, oid) in tree.items():
    status = os.stat(actual[path], follow_symlinks=False)
    executable = bool(status.st_mode & 0o111)
    if executable != (mode == b"100755"):
        raise SystemExit(f"checkout mode differs: {path}")
    expected = verified_blob(oid)
    if actual[path].read_bytes() != expected:
        raise SystemExit(f"checkout bytes differ: {path}")
