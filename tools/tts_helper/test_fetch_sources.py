#!/usr/bin/env python3
"""Offline black-box tests for pinned source checkout reuse."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
FETCH = HERE / "fetch_sources.sh"


def git(directory, *arguments):
    return subprocess.run(
        ["git", "-C", str(directory), *arguments],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


class FetchSourcesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.ggml_repo = self.root / "ggml-origin"
        self.qwen_repo = self.root / "qwen-origin"
        self._init_repo(self.ggml_repo)
        (self.ggml_repo / ".gitignore").write_text(
            "build/\n*.a\n*.dylib\nthird_party/\n", encoding="utf-8"
        )
        (self.ggml_repo / "ggml.cpp").write_text("pinned ggml\n", encoding="utf-8")
        git(self.ggml_repo, "add", ".")
        git(self.ggml_repo, "commit", "-m", "pinned ggml")
        self.ggml_commit = git(self.ggml_repo, "rev-parse", "HEAD")

        self._init_repo(self.qwen_repo)
        (self.qwen_repo / ".gitignore").write_text(
            "build/\n*.a\n*.dylib\nthird_party/\n", encoding="utf-8"
        )
        (self.qwen_repo / "qwen.cpp").write_text("pinned qwen\n", encoding="utf-8")
        git(self.qwen_repo, "add", ".")
        git(
            self.qwen_repo,
            "update-index",
            "--add",
            "--cacheinfo",
            f"160000,{self.ggml_commit},ggml",
        )
        git(self.qwen_repo, "commit", "-m", "pinned qwen")
        self.qwen_commit = git(self.qwen_repo, "rev-parse", "HEAD")

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def _init_repo(path):
        path.mkdir()
        subprocess.run(
            ["git", "init", "-q", str(path)],
            check=True,
            capture_output=True,
            text=True,
        )
        git(path, "config", "user.name", "Offline Test")
        git(path, "config", "user.email", "offline@example.invalid")

    def fetch(self, destination, environment=None):
        return subprocess.run(
            [
                str(FETCH),
                "--test-local-repositories",
                str(self.qwen_repo),
                self.qwen_commit,
                str(self.ggml_repo),
                self.ggml_commit,
                str(destination),
            ],
            env=environment,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def clean_checkout(self, name):
        destination = self.root / name
        result = self.fetch(destination)
        self.assertEqual(result.returncode, 0, result.stderr)
        return destination

    def assert_dirty_rejected(self, destination):
        result = self.fetch(destination)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stderr)

    def test_clean_exact_pins_are_accepted(self):
        destination = self.clean_checkout("clean")
        result = self.fetch(destination)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git(destination, "rev-parse", "HEAD"), self.qwen_commit)
        self.assertEqual(
            git(destination / "ggml", "rev-parse", "HEAD"),
            self.ggml_commit,
        )

    def test_tracked_dirty_is_rejected(self):
        destination = self.clean_checkout("tracked-dirty")
        (destination / "qwen.cpp").write_text("modified\n", encoding="utf-8")
        self.assert_dirty_rejected(destination)

    def test_staged_change_is_rejected(self):
        destination = self.clean_checkout("staged")
        (destination / "qwen.cpp").write_text("staged\n", encoding="utf-8")
        git(destination, "add", "qwen.cpp")
        self.assert_dirty_rejected(destination)

    def test_untracked_source_is_rejected(self):
        destination = self.clean_checkout("untracked")
        (destination / "injected.cpp").write_text("untracked\n", encoding="utf-8")
        self.assert_dirty_rejected(destination)

    def test_ignored_artifacts_are_rejected(self):
        cases = [
            ("build", "build/artifact.o"),
            ("static-library", "libpoison.a"),
            ("dynamic-library", "libpoison.dylib"),
            ("third-party", "third_party/injected.cpp"),
        ]
        for name, relative_path in cases:
            with self.subTest(name=name):
                destination = self.clean_checkout("ignored-" + name)
                artifact = destination / relative_path
                artifact.parent.mkdir(parents=True, exist_ok=True)
                artifact.write_bytes(b"ignored but forbidden")
                result = self.fetch(destination)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("missing or extra files", result.stderr)

    def test_wrong_head_is_rejected(self):
        destination = self.clean_checkout("wrong-head")
        git(destination, "config", "user.name", "Offline Test")
        git(destination, "config", "user.email", "offline@example.invalid")
        (destination / "qwen.cpp").write_text("next commit\n", encoding="utf-8")
        git(destination, "add", "qwen.cpp")
        git(destination, "commit", "-m", "wrong head")
        result = self.fetch(destination)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing checkout at unexpected commit", result.stderr)

    def test_post_checkout_injection_is_rejected_by_final_validation(self):
        fake_bin = self.root / "fake-git-bin"
        fake_bin.mkdir()
        wrapper = fake_bin / "git"
        wrapper.write_text(
            f"""#!/bin/sh
set -eu
target=
previous=
for argument in "$@"; do
    if [ "$previous" = "-C" ]; then target=$argument; fi
    previous=$argument
done
"{shutil.which("git")}" "$@"
case " $* " in
    *" checkout "*)
        printf 'injected\n' > "$target/post_checkout_injected.cpp"
        ;;
esac
""",
            encoding="utf-8",
        )
        wrapper.chmod(0o755)
        environment = os.environ.copy()
        environment.update({
            "PATH": str(fake_bin) + os.pathsep + environment["PATH"],
        })
        result = self.fetch(self.root / "hook-injection", environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing or extra files", result.stderr)

    def test_reused_executable_fsmonitor_is_never_run(self):
        destination = self.clean_checkout("fsmonitor")
        sentinel = self.root / "fsmonitor-ran"
        monitor = self.root / "monitor.sh"
        monitor.write_text(
            f"#!/bin/sh\ntouch '{sentinel}'\nexit 0\n", encoding="utf-8"
        )
        monitor.chmod(0o755)
        git(destination, "config", "core.fsmonitor", str(monitor))
        result = self.fetch(destination)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(sentinel.exists())

    def test_local_clean_filter_is_never_run_for_clean_or_dirty_checkout(self):
        destination = self.clean_checkout("clean-filter")
        sentinel = self.root / "filter-ran"
        clean_filter = self.root / "clean-filter.sh"
        clean_filter.write_text(
            f"#!/bin/sh\ntouch '{sentinel}'\ncat\n", encoding="utf-8"
        )
        clean_filter.chmod(0o755)
        git(destination, "config", "filter.probe.clean", str(clean_filter))
        info = destination / ".git" / "info" / "attributes"
        info.parent.mkdir(parents=True, exist_ok=True)
        info.write_text("qwen.cpp filter=probe\n", encoding="utf-8")
        clean = self.fetch(destination)
        self.assertEqual(clean.returncode, 0, clean.stderr)
        self.assertFalse(sentinel.exists())
        (destination / "qwen.cpp").write_text("dirty\n", encoding="utf-8")
        dirty = self.fetch(destination)
        self.assertNotEqual(dirty.returncode, 0)
        self.assertFalse(sentinel.exists())

    def test_replace_ref_is_rejected_before_materializer_can_use_it(self):
        destination = self.clean_checkout("replace")
        tree = git(destination, "write-tree")
        alternate = subprocess.run(
            ["git", "-C", str(destination), "commit-tree", tree],
            input="replacement\n",
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        git(destination, "replace", self.qwen_commit, alternate)
        result = self.fetch(destination)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("replacement refs", result.stderr)

    def test_corrupt_loose_blob_object_is_rejected_by_strict_fsck(self):
        destination = self.clean_checkout("corrupt-loose")
        oid = git(destination, "rev-parse", f"{self.qwen_commit}:qwen.cpp")
        loose = destination / ".git" / "objects" / oid[:2] / oid[2:]
        loose.parent.mkdir(parents=True, exist_ok=True)
        if loose.exists():
            loose.chmod(0o600)
        loose.write_bytes(b"not a valid compressed Git object")
        result = self.fetch(destination)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stderr)

    def test_dangerous_git_environment_is_isolated(self):
        sentinel = self.root / "environment-fsmonitor-ran"
        monitor = self.root / "environment-monitor.sh"
        monitor.write_text(
            f"#!/bin/sh\ntouch '{sentinel}'\nexit 0\n", encoding="utf-8"
        )
        monitor.chmod(0o755)
        environment = os.environ.copy()
        environment.update({
            "GIT_DIR": str(self.root / "wrong-git-dir"),
            "GIT_WORK_TREE": str(self.root / "wrong-work-tree"),
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "core.fsmonitor",
            "GIT_CONFIG_VALUE_0": str(monitor),
        })
        result = self.fetch(self.root / "isolated-environment", environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(sentinel.exists())

    def test_internal_head_mutation_cannot_change_locked_gitlink_or_prints(self):
        destination = self.root / "mutation-window"
        fake_bin = self.root / "mutation-git-bin"
        fake_bin.mkdir()
        real_git = shutil.which("git")
        wrapper = fake_bin / "git"
        wrapper.write_text(
            f"""#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import sys
REAL = {real_git!r}
DEST = {str(destination)!r}
PIN = {self.qwen_commit!r}
args = sys.argv[1:]
target = args[args.index("-C") + 1] if "-C" in args else ""
if target == DEST and "ls-tree" in args and PIN in args:
    payload = Path(DEST, "window_payload.cpp")
    if not payload.exists():
        payload.write_text("mutated\\n", encoding="utf-8")
        subprocess.run([REAL, "-C", DEST, "add", payload.name], check=True)
        subprocess.run([
            REAL, "-C", DEST, "-c", "user.name=Window",
            "-c", "user.email=window@example.invalid",
            "commit", "-m", "mutation window",
        ], check=True, stdout=subprocess.DEVNULL)
os.execv(REAL, [REAL, *args])
""",
            encoding="utf-8",
        )
        wrapper.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = str(fake_bin) + os.pathsep + environment["PATH"]
        result = self.fetch(destination, environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((destination / "window_payload.cpp").exists())
        self.assertIn("index differs from audited tree", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
