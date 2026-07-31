#!/usr/bin/env python3
"""Fail-closed scan of generated CMake/Make compiler flag files."""

import argparse
import os
from pathlib import Path
import re
import stat


DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
NATIVE_PATTERN = re.compile(br"-(?:march|mcpu|mtune)\s*=\s*native\b")


parser = argparse.ArgumentParser()
parser.add_argument("root", type=Path)
parser.add_argument("--exclude", action="append", default=[])
args = parser.parse_args()

root_fd = os.open(args.root, DIRECTORY_FLAGS)
found_makefile = False
found_flags = False


def read_regular(parent_fd, name, expected):
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)
    try:
        actual = os.fstat(descriptor)
        if (
                not stat.S_ISREG(actual.st_mode)
                or (actual.st_dev, actual.st_ino) !=
                (expected.st_dev, expected.st_ino)):
            raise SystemExit("generated flag file changed during scan")
        content = bytearray()
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            content.extend(chunk)
        after = os.fstat(descriptor)
        if (
                after.st_size != actual.st_size
                or after.st_mtime_ns != actual.st_mtime_ns
                or after.st_ctime_ns != actual.st_ctime_ns):
            raise SystemExit("generated flag file changed during scan")
        return bytes(content)
    finally:
        os.close(descriptor)


def scan(directory_fd, prefix=""):
    global found_flags, found_makefile
    for name in sorted(os.listdir(directory_fd)):
        relative = f"{prefix}/{name}" if prefix else name
        if not prefix and name in args.exclude:
            continue
        status = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if stat.S_ISDIR(status.st_mode):
            child = os.open(name, DIRECTORY_FLAGS, dir_fd=directory_fd)
            try:
                scan(child, relative)
            finally:
                os.close(child)
            continue
        is_makefile = name == "Makefile"
        is_flags = name == "flags.make"
        is_response = name.endswith(".rsp")
        if not (is_makefile or is_flags or is_response):
            continue
        if not stat.S_ISREG(status.st_mode):
            raise SystemExit(f"generated flag path is not regular: {relative}")
        content = read_regular(directory_fd, name, status)
        if NATIVE_PATTERN.search(content):
            raise SystemExit(
                f"native architecture flag found in generated file: {relative}"
            )
        found_makefile = found_makefile or is_makefile
        found_flags = found_flags or is_flags


try:
    scan(root_fd)
finally:
    os.close(root_fd)

if not found_makefile:
    raise SystemExit("expected generated Makefile was not found")
if not found_flags:
    raise SystemExit("expected generated flags.make was not found")
