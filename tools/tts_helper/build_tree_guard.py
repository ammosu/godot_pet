#!/usr/bin/env python3
"""Securely claim and content-seal the native-helper build tree."""

import base64
import hashlib
import json
import os
from pathlib import Path
import stat
import sys


DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
MANIFEST_NAME = ".tts-helper-source-manifest.json"


def type_name(mode):
    if stat.S_ISDIR(mode):
        return "directory"
    if stat.S_ISREG(mode):
        return "regular"
    if stat.S_ISLNK(mode):
        return "symlink"
    return "other"


def entry(status, content_hash=None):
    return {
        "type": type_name(status.st_mode),
        "mode": stat.S_IMODE(status.st_mode),
        "device": status.st_dev,
        "inode": status.st_ino,
        "size": status.st_size,
        "sha256": content_hash,
    }


def open_root(path):
    try:
        descriptor = os.open(path, DIRECTORY_FLAGS)
    except OSError as error:
        raise SystemExit(
            f"helper build path is not a physical directory: {error}"
        ) from None
    return descriptor


def open_canonical_parent(path):
    if not path.is_absolute() or path.name in ("", ".", ".."):
        raise SystemExit("helper build path must be canonical and absolute")
    descriptor = os.open("/", DIRECTORY_FLAGS)
    try:
        for component in path.parent.parts[1:]:
            if component in ("", ".", ".."):
                raise SystemExit("helper build path is not canonical")
            child = os.open(component, DIRECTORY_FLAGS, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def directory_identity(descriptor):
    status = os.fstat(descriptor)
    if not stat.S_ISDIR(status.st_mode):
        raise SystemExit("helper build path is not a physical directory")
    return entry(status)


def critical_directory_identity(descriptor):
    status = os.fstat(descriptor)
    if not stat.S_ISDIR(status.st_mode):
        raise SystemExit("helper build path is not a physical directory")
    return {
        "type": "directory",
        "device": status.st_dev,
        "inode": status.st_ino,
    }


def open_descendant(root_fd, components):
    descriptor = os.dup(root_fd)
    try:
        for component in components:
            child = os.open(component, DIRECTORY_FLAGS, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def hash_regular_file(parent_fd, name, expected):
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)
    try:
        actual = os.fstat(descriptor)
        if (
                not stat.S_ISREG(actual.st_mode)
                or (actual.st_dev, actual.st_ino) !=
                (expected.st_dev, expected.st_ino)):
            raise SystemExit("source file changed while creating manifest")
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(descriptor)
        if (
                after.st_size != actual.st_size
                or after.st_mtime_ns != actual.st_mtime_ns
                or after.st_ctime_ns != actual.st_ctime_ns):
            raise SystemExit("source file changed while creating manifest")
        return digest.hexdigest(), after
    finally:
        os.close(descriptor)


def scan_source_directory(directory_fd, prefix, result):
    for name in sorted(os.listdir(directory_fd)):
        if name in ("", ".", "..") or "/" in name:
            raise SystemExit("invalid source tree entry")
        relative = f"{prefix}/{name}" if prefix else name
        status = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        kind = type_name(status.st_mode)
        if kind == "directory":
            child = os.open(name, DIRECTORY_FLAGS, dir_fd=directory_fd)
            try:
                verified = os.fstat(child)
                if (verified.st_dev, verified.st_ino) != (
                        status.st_dev, status.st_ino):
                    raise SystemExit(
                        "source directory changed while creating manifest"
                    )
                result[relative] = entry(verified)
                scan_source_directory(child, relative, result)
            finally:
                os.close(child)
        elif kind == "regular":
            digest, verified = hash_regular_file(directory_fd, name, status)
            result[relative] = entry(verified, digest)
        elif kind == "symlink":
            target = os.readlink(name, dir_fd=directory_fd)
            digest = hashlib.sha256(os.fsencode(target)).hexdigest()
            result[relative] = entry(status, digest)
        else:
            raise SystemExit(f"unsupported source tree entry: {relative}")


def source_manifest(root_fd):
    sources_fd = open_descendant(root_fd, ("sources",))
    result = {}
    try:
        result["sources"] = directory_identity(sources_fd)
        scan_source_directory(sources_fd, "sources", result)
    finally:
        os.close(sources_fd)
    return result


def snapshot_from_root(root_fd):
    critical = {}
    for components in ((), ("deps",), ("deps", "ggml")):
        label = "/".join(components) or "root"
        try:
            descriptor = open_descendant(root_fd, components)
        except OSError as error:
            raise SystemExit(
                f"critical helper build directory changed ({label}): {error}"
            ) from None
        try:
            critical[label] = critical_directory_identity(descriptor)
        finally:
            os.close(descriptor)
    return {
        "version": 1,
        "critical": critical,
        "sources": source_manifest(root_fd),
    }


def canonical_json(value):
    return json.dumps(
        value, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def encode_token(value):
    raw = canonical_json(value)
    return base64.urlsafe_b64encode(raw).decode("ascii")


def decode_token(value):
    try:
        raw = base64.b64decode(
            value.encode("ascii"), altchars=b"-_", validate=True
        )
        decoded = json.loads(raw)
    except (UnicodeError, ValueError, json.JSONDecodeError):
        raise SystemExit("invalid helper build-tree seal") from None
    if not isinstance(decoded, dict):
        raise SystemExit("invalid helper build-tree seal")
    return decoded


def write_manifest(root_fd, value):
    raw = canonical_json(value)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    descriptor = os.open(MANIFEST_NAME, flags, 0o600, dir_fd=root_fd)
    try:
        view = memoryview(raw)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
        os.fsync(descriptor)
        status = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    return {
        "manifest": MANIFEST_NAME,
        "device": status.st_dev,
        "inode": status.st_ino,
        "mode": stat.S_IMODE(status.st_mode),
        "size": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
    }


def read_verified_manifest(root_fd, token):
    if token.get("manifest") != MANIFEST_NAME:
        raise SystemExit("invalid helper build-tree seal")
    descriptor = os.open(
        MANIFEST_NAME, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=root_fd
    )
    try:
        status = os.fstat(descriptor)
        if not stat.S_ISREG(status.st_mode):
            raise SystemExit("helper build-tree manifest is not regular")
        raw = bytearray()
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            raw.extend(chunk)
    finally:
        os.close(descriptor)
    actual = {
        "manifest": MANIFEST_NAME,
        "device": status.st_dev,
        "inode": status.st_ino,
        "mode": stat.S_IMODE(status.st_mode),
        "size": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
    }
    if actual != token:
        raise SystemExit("helper build-tree manifest identity or hash changed")
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise SystemExit("invalid helper build-tree manifest") from None
    if canonical_json(value) != bytes(raw):
        raise SystemExit("non-canonical helper build-tree manifest")
    return value


def root_identity(path):
    descriptor = open_root(path)
    try:
        identity = directory_identity(descriptor)
    finally:
        os.close(descriptor)
    return f"{identity['device']}:{identity['inode']}"


def claim(path):
    parent_fd = open_canonical_parent(path)
    child_fd = None
    try:
        victim = os.environ.get("TTS_BUILD_GUARD_TEST_PARENT_SWAP_VICTIM")
        if victim is not None:
            held = path.parent.with_name(
                path.parent.name + ".held-parent-after-test-swap"
            )
            os.rename(path.parent, held)
            os.symlink(victim, path.parent)
        try:
            os.mkdir(path.name, 0o700, dir_fd=parent_fd)
        except FileExistsError:
            raise SystemExit(f"refusing existing helper build path: {path}")
        child_fd = os.open(path.name, DIRECTORY_FLAGS, dir_fd=parent_fd)
        identity = directory_identity(child_fd)
        print(f"{identity['device']}:{identity['inode']}")
    finally:
        if child_fd is not None:
            os.close(child_fd)
        os.close(parent_fd)


if len(sys.argv) < 3:
    raise SystemExit(
        "usage: build_tree_guard.py claim|check|seal|check-all PATH [TOKEN]"
    )

operation, raw_path = sys.argv[1:3]
path = Path(raw_path)
if operation == "claim" and len(sys.argv) == 3:
    claim(path)
elif operation == "check" and len(sys.argv) == 4:
    if root_identity(path) != sys.argv[3]:
        raise SystemExit("helper build directory identity changed")
elif operation == "seal" and len(sys.argv) == 3:
    root_fd = open_root(path)
    try:
        token = write_manifest(root_fd, snapshot_from_root(root_fd))
    finally:
        os.close(root_fd)
    print(encode_token(token))
elif operation == "check-all" and len(sys.argv) == 4:
    token = decode_token(sys.argv[3])
    root_fd = open_root(path)
    try:
        expected = read_verified_manifest(root_fd, token)
        actual = snapshot_from_root(root_fd)
    finally:
        os.close(root_fd)
    if actual != expected:
        raise SystemExit("critical helper source/build manifest changed")
else:
    raise SystemExit("invalid build tree guard operation")
