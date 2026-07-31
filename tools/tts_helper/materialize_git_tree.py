#!/usr/bin/env python3
"""Materialize both locked source trees beneath one claimed build-root fd."""

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess


DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def git_environment():
    return {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": os.environ.get("TMPDIR", "/tmp"),
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
    }


def safe_git(repository, *arguments, **kwargs):
    git = shutil.which("git")
    if git is None:
        raise SystemExit("git is required")
    return subprocess.run(
        [
            git, "-c", "core.hooksPath=/dev/null",
            "-c", "core.fsmonitor=false", "-C", str(repository), *arguments,
        ],
        env=git_environment(),
        check=True,
        **kwargs,
    )


def parse_identity(raw_identity):
    try:
        device, inode = (int(value) for value in raw_identity.split(":"))
    except (TypeError, ValueError):
        raise SystemExit("invalid claimed build-root identity") from None
    return device, inode


def verify_directory(descriptor, expected_identity=None):
    status = os.fstat(descriptor)
    if not stat.S_ISDIR(status.st_mode):
        raise SystemExit("helper build path is not a physical directory")
    if expected_identity is not None and (
            status.st_dev, status.st_ino) != expected_identity:
        raise SystemExit("helper build directory identity changed")


def create_directory(parent_fd, name):
    try:
        os.mkdir(name, 0o700, dir_fd=parent_fd)
    except FileExistsError:
        pass
    descriptor = os.open(name, DIRECTORY_FLAGS, dir_fd=parent_fd)
    verify_directory(descriptor)
    return descriptor


def safe_tree_entries(repository, commit):
    tree = safe_git(
        repository, "ls-tree", "-rz", commit, stdout=subprocess.PIPE
    ).stdout
    for record in tree.split(b"\0"):
        if not record:
            continue
        try:
            metadata, raw_name = record.split(b"\t", 1)
            mode, object_type, object_id = metadata.split(b" ", 2)
            object_id_text = object_id.decode("ascii")
        except (UnicodeDecodeError, ValueError):
            raise SystemExit("refusing malformed Git tree entry") from None
        path = PurePosixPath(os.fsdecode(raw_name))
        if path.is_absolute() or not path.parts or any(
                part in ("", ".", "..") for part in path.parts):
            raise SystemExit(f"refusing unsafe Git tree path: {path!s}")
        yield mode, object_type, object_id_text, path


def object_format(repository):
    value = safe_git(
        repository, "rev-parse", "--show-object-format",
        stdout=subprocess.PIPE,
    ).stdout.decode("ascii").strip()
    if value not in ("sha1", "sha256"):
        raise SystemExit(f"unsupported Git object format: {value}")
    return value


def write_verified_blob(repository, object_id, hash_name, output):
    size_text = safe_git(
        repository, "cat-file", "-s", object_id, stdout=subprocess.PIPE
    ).stdout.decode("ascii").strip()
    try:
        expected_size = int(size_text)
    except ValueError:
        raise SystemExit(f"invalid Git blob size for {object_id}") from None
    if expected_size < 0:
        raise SystemExit(f"invalid Git blob size for {object_id}")

    digest = hashlib.new(hash_name)
    digest.update(f"blob {expected_size}\0".encode("ascii"))
    git = shutil.which("git")
    process = subprocess.Popen(
        [
            git, "-c", "core.hooksPath=/dev/null",
            "-c", "core.fsmonitor=false", "-C", str(repository),
            "cat-file", "blob", object_id,
        ],
        env=git_environment(),
        stdout=subprocess.PIPE,
    )
    actual_size = 0
    assert process.stdout is not None
    while True:
        chunk = process.stdout.read(65536)
        if not chunk:
            break
        actual_size += len(chunk)
        if actual_size > expected_size:
            process.kill()
            process.wait()
            raise SystemExit(f"Git blob size mismatch: {object_id}")
        digest.update(chunk)
        output.write(chunk)
    if process.wait() != 0:
        raise SystemExit(f"Git failed to read blob: {object_id}")
    if actual_size != expected_size or digest.hexdigest() != object_id:
        raise SystemExit(f"Git blob object ID mismatch: {object_id}")


def materialize_tree(repository, commit, root_fd, expected_gitlink=None):
    safe_git(
        repository, "fsck", "--strict", "--no-dangling", commit,
        stdout=subprocess.DEVNULL,
    )
    hash_name = object_format(repository)
    gitlinks = []
    for mode, object_type, object_id, path in safe_tree_entries(
            repository, commit):
        if mode == b"160000" and object_type == b"commit":
            if (
                    expected_gitlink is not None
                    and path == PurePosixPath("ggml")
                    and object_id == expected_gitlink):
                gitlinks.append(object_id)
                continue
            raise SystemExit(f"refusing unexpected Git link: {path!s}")
        if mode not in (b"100644", b"100755") or object_type != b"blob":
            raise SystemExit(
                f"refusing unsupported Git mode {mode!r} at {path!s}"
            )

        directory_fd = os.dup(root_fd)
        try:
            for component in path.parts[:-1]:
                child_fd = create_directory(directory_fd, component)
                os.close(directory_fd)
                directory_fd = child_fd
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
            file_fd = os.open(path.name, flags, 0o700, dir_fd=directory_fd)
            with os.fdopen(file_fd, "wb", closefd=True) as output:
                write_verified_blob(repository, object_id, hash_name, output)
                os.fchmod(
                    output.fileno(), 0o755 if mode == b"100755" else 0o644
                )
        finally:
            os.close(directory_fd)

    if expected_gitlink is not None and gitlinks != [expected_gitlink]:
        raise SystemExit(
            "qwen tree does not contain exactly the audited ggml gitlink"
        )


def exercise_sources_swap_test_seam(root_fd):
    victim = os.environ.get("TTS_MATERIALIZER_TEST_SOURCES_VICTIM")
    if victim is None:
        return
    if any(character in victim for character in "\r\n\0"):
        raise SystemExit("invalid materializer test victim path")
    os.rename(
        "sources", "held-sources-after-test-swap",
        src_dir_fd=root_fd, dst_dir_fd=root_fd,
    )
    os.symlink(victim, "sources", dir_fd=root_fd)


def patch_qwen_cmake(qwen_fd):
    descriptor = os.open(
        "CMakeLists.txt", os.O_RDWR | os.O_NOFOLLOW, dir_fd=qwen_fd
    )
    try:
        status = os.fstat(descriptor)
        if not stat.S_ISREG(status.st_mode):
            raise SystemExit("refusing non-regular qwen CMakeLists.txt")
        data = bytearray()
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            data.extend(chunk)
        needle = (
            b'set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} '
            b'-O3 -march=native")'
        )
        replacement = (
            b'set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3")'
        )
        if data.count(needle) != 1:
            raise SystemExit(
                "expected exactly one pinned qwen -march=native release flag"
            )
        updated = bytes(data).replace(needle, replacement)
        os.lseek(descriptor, 0, os.SEEK_SET)
        os.ftruncate(descriptor, 0)
        view = memoryview(updated)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def create_controlled_ggml_build_link(
        root_fd, qwen_ggml_fd, held_ggml_build_fd):
    deps_fd = os.open("deps", DIRECTORY_FLAGS, dir_fd=root_fd)
    checked_ggml_fd = None
    try:
        checked_ggml_fd = os.open(
            "ggml", DIRECTORY_FLAGS, dir_fd=deps_fd
        )
        expected = os.fstat(held_ggml_build_fd)
        actual = os.fstat(checked_ggml_fd)
        if (actual.st_dev, actual.st_ino) != (
                expected.st_dev, expected.st_ino):
            raise SystemExit("held ggml build directory identity changed")
    finally:
        if checked_ggml_fd is not None:
            os.close(checked_ggml_fd)
        os.close(deps_fd)

    target = "../../../deps/ggml"
    os.symlink(target, "build", dir_fd=qwen_ggml_fd)
    if os.readlink("build", dir_fd=qwen_ggml_fd) != target:
        raise SystemExit("ggml build link target changed during creation")


parser = argparse.ArgumentParser()
parser.add_argument("build_root", type=Path)
parser.add_argument("root_identity")
parser.add_argument("qwen_repository", type=Path)
parser.add_argument("qwen_commit")
parser.add_argument("ggml_repository", type=Path)
parser.add_argument("ggml_commit")
args = parser.parse_args()

root_fd = os.open(args.build_root, DIRECTORY_FLAGS)
sources_fd = qwen_fd = qwen_ggml_fd = deps_fd = ggml_build_fd = None
try:
    verify_directory(root_fd, parse_identity(args.root_identity))
    sources_fd = create_directory(root_fd, "sources")
    qwen_fd = create_directory(sources_fd, "qwen")
    qwen_ggml_fd = create_directory(qwen_fd, "ggml")
    deps_fd = create_directory(root_fd, "deps")
    ggml_build_fd = create_directory(deps_fd, "ggml")

    materialize_tree(
        args.qwen_repository, args.qwen_commit, qwen_fd, args.ggml_commit
    )
    patch_qwen_cmake(qwen_fd)
    exercise_sources_swap_test_seam(root_fd)
    materialize_tree(
        args.ggml_repository, args.ggml_commit, qwen_ggml_fd
    )
    create_controlled_ggml_build_link(
        root_fd, qwen_ggml_fd, ggml_build_fd
    )
finally:
    for descriptor in (
            ggml_build_fd, deps_fd, qwen_ggml_fd, qwen_fd, sources_fd, root_fd):
        if descriptor is not None:
            os.close(descriptor)
