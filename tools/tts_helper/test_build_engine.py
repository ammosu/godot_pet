#!/usr/bin/env python3
"""Offline tests for the native helper build-tree isolation policy."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
BUILD = HERE / "build_engine.sh"


def git(directory, *arguments):
    return subprocess.run(
        ["git", "-C", str(directory), *arguments],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


class BuildEngineTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.ggml_repo = self.root / "ggml-origin"
        self.qwen_repo = self.root / "qwen-origin"
        self._init_repo(self.ggml_repo)
        (self.ggml_repo / ".gitignore").write_text("build/\n", encoding="utf-8")
        (self.ggml_repo / "ggml.cpp").write_text("ggml\n", encoding="utf-8")
        git(self.ggml_repo, "add", ".")
        git(self.ggml_repo, "commit", "-m", "ggml")
        self.ggml_commit = git(self.ggml_repo, "rev-parse", "HEAD")

        self._init_repo(self.qwen_repo)
        (self.qwen_repo / ".gitignore").write_text("build/\n", encoding="utf-8")
        (self.qwen_repo / "qwen.cpp").write_text("qwen\n", encoding="utf-8")
        (self.qwen_repo / "CMakeLists.txt").write_text(
            'set(CMAKE_CXX_FLAGS_RELEASE '
            '"${CMAKE_CXX_FLAGS_RELEASE} -O3 -march=native")\n',
            encoding="utf-8",
        )
        git(self.qwen_repo, "add", ".")
        git(
            self.qwen_repo,
            "update-index",
            "--add",
            "--cacheinfo",
            f"160000,{self.ggml_commit},ggml",
        )
        git(self.qwen_repo, "commit", "-m", "qwen")
        self.qwen_commit = git(self.qwen_repo, "rev-parse", "HEAD")

        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        self.fake_bin = fake_bin
        self.cmake_log = self.root / "cmake.log"
        fake_cmake = fake_bin / "cmake"
        fake_cmake.write_text(
            """#!/bin/sh
set -eux
printf '%s\n' "$*" >> "$FAKE_CMAKE_LOG"
test -L "$EXPECTED_SOURCE_LINK"
test "$(readlink "$EXPECTED_SOURCE_LINK")" = "../../../deps/ggml"
case " $* " in
    *" -S "*)
        case " $* " in *" -G Unix Makefiles "*) ;; *) exit 94 ;; esac
        case " $* " in *" -DGGML_NATIVE=OFF"*) ;; *) exit 95 ;; esac
        previous=
        configured=
        for argument in "$@"; do
            if [ "$previous" = "-B" ]; then configured=$argument; fi
            previous=$argument
        done
        test -n "$configured"
        mkdir -p "$configured/CMakeFiles/fake.dir"
        printf 'all:\n' > "$configured/Makefile"
        if [ "${FAKE_MISSING_FLAGS:-0}" != 1 ]; then
            printf 'CXX_FLAGS = -O2\n' \
                > "$configured/CMakeFiles/fake.dir/flags.make"
        fi
        if [ "${FAKE_INJECT_NATIVE_FLAGS:-0}" = 1 ]; then
            printf 'CXX_FLAGS = -mcpu=native -mtune=native\n' \
                > "$configured/CMakeFiles/fake.dir/flags.make"
        fi
        if [ "${FAKE_SWAP_CRITICAL_AFTER_CONFIGURE:-0}" = 1 ] &&
                [ ! -e "$FAKE_SWAP_MARKER" ]; then
            touch "$FAKE_SWAP_MARKER"
            mv "$EXPECTED_BUILD_ROOT/deps" "$EXPECTED_BUILD_ROOT/held-deps"
            ln -s "$FAKE_SWAP_VICTIM" "$EXPECTED_BUILD_ROOT/deps"
        fi
        if [ "${FAKE_MUTATE_SOURCE_AFTER_CONFIGURE:-0}" = 1 ] &&
                [ ! -e "$FAKE_SOURCE_MUTATE_MARKER" ]; then
            touch "$FAKE_SOURCE_MUTATE_MARKER"
            printf '# mutated\n' >> "$EXPECTED_BUILD_SOURCE/CMakeLists.txt"
        fi
        if [ "${FAKE_SWAP_SOURCE_DIR_AFTER_CONFIGURE:-0}" = 1 ] &&
                [ ! -e "$FAKE_SOURCE_SWAP_MARKER" ]; then
            touch "$FAKE_SOURCE_SWAP_MARKER"
            mv "$EXPECTED_BUILD_SOURCE" "$EXPECTED_BUILD_ROOT/held-qwen"
            mkdir "$EXPECTED_BUILD_SOURCE"
        fi
        ;;
esac
if grep -q -- '-march=native' "$EXPECTED_BUILD_SOURCE/CMakeLists.txt"; then
    exit 93
fi
if [ "${FAKE_CMAKE_FAIL:-0}" = 1 ]; then
    exit 77
fi
case "$*" in
    *"--target godot-pet-tts-helper"*)
        case "${FAKE_OUTPUT_LAYOUT:-root}" in
            root) output="$EXPECTED_BUILD_ROOT/godot-pet-tts-helper" ;;
            release)
                mkdir -p "$EXPECTED_BUILD_ROOT/Release"
                output="$EXPECTED_BUILD_ROOT/Release/godot-pet-tts-helper"
                ;;
            missing) exit 0 ;;
        esac
        cat > "$output" <<'ARTIFACT'
#!/bin/sh
set -eu
case "${1:-}" in
    --protocol-version)
        printf '1\n'
        ;;
    --self-test)
        printf '{"ok":true,"protocol":1,"engine":"fake-qwen"}\n'
        if [ "${FAKE_ARTIFACT_SWAP_ON_SELF_TEST:-0}" = 1 ]; then
            cp "$FAKE_ARTIFACT_REPLACEMENT" "$0.replacement"
            chmod +x "$0.replacement"
            mv "$0.replacement" "$0"
        fi
        ;;
    *)
        exit 2
        ;;
esac
ARTIFACT
        chmod +x "$output"
        ;;
esac
""",
            encoding="utf-8",
        )
        fake_cmake.chmod(0o755)
        self.environment = os.environ.copy()
        self.environment.update({
            "PATH": str(fake_bin) + os.pathsep + self.environment["PATH"],
            "FAKE_CMAKE_LOG": str(self.cmake_log),
            "TTS_HELPER_EXPECTED_ENGINE": "fake-qwen",
            "TTS_HELPER_TEST_SKIP_OTOOL": "1",
        })

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

    def install_git_race(self, source, build, action):
        real_git = subprocess.run(
            ["/usr/bin/which", "git"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        wrapper = self.fake_bin / "git"
        wrapper.write_text(
            """#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import sys

REAL_GIT = __REAL_GIT__
SOURCE = __SOURCE__
AUDITED = __AUDITED__
ACTION = __ACTION__
MARKER = __MARKER__
BUILD = __BUILD__
VICTIM = __VICTIM__
arguments = sys.argv[1:]
target = arguments[arguments.index("-C") + 1] if "-C" in arguments else ""
if ACTION == "swap-build" and "fetch" in arguments and not Path(MARKER).exists():
    Path(MARKER).touch()
    os.rmdir(BUILD)
    os.symlink(VICTIM, BUILD)
trigger = (
    target == SOURCE and "ls-tree" in arguments and "-rz" in arguments
    and AUDITED in arguments and not Path(MARKER).exists()
)
if trigger:
    Path(MARKER).touch()
    if ACTION == "switch":
        Path(SOURCE, "race_payload.cpp").write_text("raced\\n", encoding="utf-8")
        subprocess.run([REAL_GIT, "-C", SOURCE, "add", "race_payload.cpp"], check=True)
        subprocess.run([
            REAL_GIT, "-C", SOURCE, "-c", "user.name=Race Test",
            "-c", "user.email=race@example.invalid", "commit", "-m", "raced HEAD",
        ], check=True, stdout=subprocess.DEVNULL)
    elif ACTION == "delete":
        subprocess.run([
            REAL_GIT, "-C", SOURCE, "symbolic-ref", "HEAD",
            "refs/heads/deleted-race",
        ], check=True)
    elif ACTION == "attributes":
        attributes = Path(MARKER).with_suffix(".attributes")
        attributes.write_text("qwen.cpp export-ignore\\n", encoding="utf-8")
        subprocess.run([
            REAL_GIT, "-C", SOURCE, "config", "core.attributesFile",
            str(attributes),
        ], check=True)
        info = Path(SOURCE, ".git", "info", "attributes")
        info.parent.mkdir(parents=True, exist_ok=True)
        info.write_text("qwen.cpp export-ignore\\n", encoding="utf-8")
os.execv(REAL_GIT, [REAL_GIT, *arguments])
"""
            .replace("__REAL_GIT__", repr(real_git))
            .replace("__SOURCE__", repr(str(source)))
            .replace("__AUDITED__", repr(self.qwen_commit))
            .replace("__ACTION__", repr(action))
            .replace("__MARKER__", repr(str(self.root / ("race-" + action))))
            .replace("__BUILD__", repr(str(build)))
            .replace("__VICTIM__", repr(str(self.root / "swap-victim"))),
            encoding="utf-8",
        )
        wrapper.chmod(0o755)

    def run_build(
            self, name, fail=False, prepare_build=None, layout="root", race=None,
            critical_swap=False, mutate_source=False, swap_source_dir=False,
            artifact_swap=False, missing_flags=False):
        source = (self.root / (name + "-source")).resolve()
        build = (self.root / (name + "-build")).resolve()
        if race is not None:
            if race == "swap-build":
                victim = self.root / "swap-victim"
                victim.mkdir()
                (victim / "sentinel").write_text("preserve", encoding="utf-8")
            self.install_git_race(source, build, race)
        if prepare_build is not None:
            prepare_build(build)
        external = build / "deps" / "ggml"
        source_link = build / "sources" / "qwen" / "ggml" / "build"
        environment = self.environment.copy()
        environment.update({
            "QWEN3_TTS_SOURCE": str(source),
            "TTS_HELPER_BUILD_DIR": str(build),
            "EXPECTED_SOURCE_LINK": str(source_link),
            "EXPECTED_EXTERNAL_BUILD": str(external),
            "EXPECTED_BUILD_SOURCE": str(build / "sources" / "qwen"),
            "EXPECTED_BUILD_ROOT": str(build),
            "FAKE_CMAKE_FAIL": "1" if fail else "0",
            "FAKE_OUTPUT_LAYOUT": layout,
            "FAKE_INJECT_NATIVE_FLAGS": "0",
            "FAKE_MISSING_FLAGS": "1" if missing_flags else "0",
            "FAKE_SWAP_CRITICAL_AFTER_CONFIGURE":
                "1" if critical_swap else "0",
            "FAKE_SWAP_MARKER": str(self.root / (name + "-critical-swap")),
            "FAKE_SWAP_VICTIM": str(self.root / (name + "-critical-victim")),
            "FAKE_MUTATE_SOURCE_AFTER_CONFIGURE":
                "1" if mutate_source else "0",
            "FAKE_SOURCE_MUTATE_MARKER":
                str(self.root / (name + "-source-mutate")),
            "FAKE_SWAP_SOURCE_DIR_AFTER_CONFIGURE":
                "1" if swap_source_dir else "0",
            "FAKE_SOURCE_SWAP_MARKER":
                str(self.root / (name + "-source-swap")),
            "FAKE_ARTIFACT_SWAP_ON_SELF_TEST":
                "1" if artifact_swap else "0",
            "FAKE_ARTIFACT_REPLACEMENT":
                str(self.root / (name + "-artifact-replacement")),
        })
        if artifact_swap:
            replacement = self.root / (name + "-artifact-replacement")
            replacement.write_text("#!/bin/sh\nexit 99\n", encoding="utf-8")
            replacement.chmod(0o755)
        if critical_swap:
            victim = self.root / (name + "-critical-victim")
            victim.mkdir()
            (victim / "sentinel").write_text("preserve", encoding="utf-8")
        if race == "swap-sources-after-qwen":
            victim = self.root / "sources-swap-victim"
            victim.mkdir()
            (victim / "sentinel").write_text("preserve", encoding="utf-8")
            victim_ggml = victim / "qwen" / "ggml"
            victim_ggml.mkdir(parents=True)
            (victim / "qwen" / "CMakeLists.txt").write_text(
                "victim-cmake\n", encoding="utf-8"
            )
            (victim_ggml / "build").symlink_to("victim-build-target")
            environment["TTS_MATERIALIZER_TEST_SOURCES_VICTIM"] = str(victim)
        result = subprocess.run(
            [
                str(BUILD),
                "--test-local-repositories",
                str(self.qwen_repo),
                self.qwen_commit,
                str(self.ggml_repo),
                self.ggml_commit,
            ],
            env=environment,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
        return result, source, build, source_link, external

    def test_external_ggml_build_and_success_cleanup(self):
        result, source, _, source_link, external = self.run_build("success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(source_link.is_symlink())
        log = self.cmake_log.read_text(encoding="utf-8")
        self.assertIn(f"-B {external}", log)
        self.assertIn(f"--build {external}", log)
        self.assertNotIn(str(source / "ggml" / "build"), log)
        self.assertFalse((source / "ggml" / "build").exists())
        self.assertEqual(git(source, "status", "--porcelain", "--ignored"), "")
        self.assertEqual(
            git(source / "ggml", "status", "--porcelain", "--ignored"), ""
        )

    def test_failure_never_modifies_audited_source(self):
        result, source, _, source_link, _ = self.run_build("failure", fail=True)
        self.assertEqual(result.returncode, 77)
        self.assertTrue(source_link.is_symlink())
        self.assertFalse((source / "ggml" / "build").exists())

    def test_nonempty_build_directory_is_refused_without_deleting_it(self):
        def poison(build):
            build.mkdir()
            (build / "CMakeCache.txt").write_text("poison", encoding="utf-8")

        result, source, build, source_link, _ = self.run_build(
            "nonempty", prepare_build=poison
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing existing helper build path", result.stderr)
        self.assertEqual((build / "CMakeCache.txt").read_text(), "poison")
        self.assertFalse(source.exists())
        self.assertFalse(source_link.exists())

    def test_release_configuration_executable_is_discovered(self):
        result, _, build, _, _ = self.run_build("release", layout="release")
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(result.stdout.splitlines()[-1])
        self.assertEqual(
            manifest["artifact"],
            str(build / "Release" / "godot-pet-tts-helper"),
        )
        self.assertEqual(manifest["engine"], "fake-qwen")
        self.assertRegex(manifest["sha256"], r"^[0-9a-f]{64}$")

    def test_missing_executable_is_rejected(self):
        result, _, _, _, _ = self.run_build("missing", layout="missing")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected exactly one regular helper executable", result.stderr)

    def test_missing_generated_flags_file_fails_closed_before_build(self):
        result, _, _, _, _ = self.run_build(
            "missing-flags", missing_flags=True
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected generated flags.make was not found", result.stderr)
        self.assertEqual(
            len(self.cmake_log.read_text(encoding="utf-8").splitlines()), 1
        )

    def test_generated_mcpu_or_mtune_native_flags_are_rejected(self):
        source = (self.root / "native-source").resolve()
        build = (self.root / "native-build").resolve()
        environment = self.environment.copy()
        environment.update({
            "QWEN3_TTS_SOURCE": str(source),
            "TTS_HELPER_BUILD_DIR": str(build),
            "EXPECTED_SOURCE_LINK": str(
                build / "sources" / "qwen" / "ggml" / "build"
            ),
            "EXPECTED_EXTERNAL_BUILD": str(build / "deps" / "ggml"),
            "EXPECTED_BUILD_SOURCE": str(build / "sources" / "qwen"),
            "EXPECTED_BUILD_ROOT": str(build),
            "FAKE_CMAKE_FAIL": "0",
            "FAKE_OUTPUT_LAYOUT": "root",
            "FAKE_INJECT_NATIVE_FLAGS": "1",
        })
        result = subprocess.run(
            [
                str(BUILD), "--test-local-repositories",
                str(self.qwen_repo), self.qwen_commit,
                str(self.ggml_repo), self.ggml_commit,
            ],
            env=environment,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("native architecture flag found", result.stderr)

    def test_dotdot_and_symlink_alias_overlap_preserve_sentinel(self):
        shared = self.root / "shared"
        shared.mkdir()
        sentinel = shared / "sentinel"
        sentinel.write_text("preserve", encoding="utf-8")
        alias = self.root / "source-alias"
        alias.symlink_to(shared, target_is_directory=True)
        build = shared / "nested-build"
        environment = self.environment.copy()
        environment.update({
            "QWEN3_TTS_SOURCE": str(self.root / "x" / ".." / "source-alias"),
            "TTS_HELPER_BUILD_DIR": str(build),
        })
        result = subprocess.run(
            [
                str(BUILD), "--test-local-repositories",
                str(self.qwen_repo), self.qwen_commit,
                str(self.ggml_repo), self.ggml_commit,
            ],
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("overlapping source and helper build paths", result.stderr)
        self.assertEqual(sentinel.read_text(), "preserve")
        self.assertFalse(build.exists())

    def test_newline_path_is_rejected_and_sentinel_is_preserved(self):
        sentinel = self.root / "newline-sentinel"
        sentinel.write_text("preserve", encoding="utf-8")
        environment = self.environment.copy()
        environment.update({
            "QWEN3_TTS_SOURCE": str(self.root / "source\ninjected"),
            "TTS_HELPER_BUILD_DIR": str(self.root / "newline-build"),
        })
        result = subprocess.run(
            [
                str(BUILD), "--test-local-repositories",
                str(self.qwen_repo), self.qwen_commit,
                str(self.ggml_repo), self.ggml_commit,
            ],
            env=environment,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CR, LF, or NUL", result.stderr)
        self.assertEqual(sentinel.read_text(), "preserve")

    def test_absolute_symlink_tree_entry_is_rejected_without_touching_sentinel(self):
        sentinel = self.root / "outside-sentinel"
        sentinel.write_text("preserve", encoding="utf-8")
        (self.qwen_repo / "absolute-link").symlink_to(sentinel)
        git(self.qwen_repo, "add", "absolute-link")
        git(self.qwen_repo, "commit", "-m", "malicious symlink")
        self.qwen_commit = git(self.qwen_repo, "rev-parse", "HEAD")
        result, _, _, _, _ = self.run_build("symlink-tree")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported checkout tree entry", result.stderr)
        self.assertEqual(sentinel.read_text(), "preserve")

    def test_head_switch_after_fetch_cannot_change_materialized_tree(self):
        result, source, build, _, _ = self.run_build("head-switch", race="switch")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((source / "race_payload.cpp").exists())
        self.assertFalse(
            (build / "sources" / "qwen" / "race_payload.cpp").exists()
        )
        self.assertNotEqual(git(source, "rev-parse", "HEAD"), self.qwen_commit)

    def test_deleted_head_does_not_block_materializing_audited_object(self):
        result, source, build, _, _ = self.run_build("head-delete", race="delete")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((build / "sources" / "qwen" / "qwen.cpp").exists())
        head = subprocess.run(
            ["git", "-C", str(source), "rev-parse", "--verify", "HEAD"],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(head.returncode, 0)

    def test_export_ignore_attributes_cannot_remove_locked_blob(self):
        result, _, build, _, _ = self.run_build("attributes", race="attributes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((build / "sources" / "qwen" / "qwen.cpp").exists())

    def test_materializer_recomputes_blob_oid_and_rejects_tampered_cat_file(self):
        source = (self.root / "tampered-cat-source").resolve()
        fetched = subprocess.run(
            [
                str(HERE / "fetch_sources.sh"), "--test-local-repositories",
                str(self.qwen_repo), self.qwen_commit,
                str(self.ggml_repo), self.ggml_commit, str(source),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(fetched.returncode, 0, fetched.stderr)
        build = (self.root / "tampered-cat-build").resolve()
        claimed = subprocess.run(
            [
                "python3", str(HERE / "build_tree_guard.py"),
                "claim", str(build),
            ],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        real_git = subprocess.run(
            ["/usr/bin/which", "git"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        wrapper = self.fake_bin / "git"
        wrapper.write_text(
            f"""#!/usr/bin/env python3
import os
import subprocess
import sys
REAL = {real_git!r}
args = sys.argv[1:]
if "cat-file" in args and "blob" in args:
    result = subprocess.run([REAL, *args], check=True, capture_output=True)
    data = bytearray(result.stdout)
    if data:
        data[0] ^= 1
    sys.stdout.buffer.write(data)
    raise SystemExit(0)
os.execv(REAL, [REAL, *args])
""",
            encoding="utf-8",
        )
        wrapper.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = (
            str(self.fake_bin) + os.pathsep + environment["PATH"]
        )
        result = subprocess.run(
            [
                "python3", str(HERE / "materialize_git_tree.py"),
                str(build), claimed,
                str(source), self.qwen_commit,
                str(source / "ggml"), self.ggml_commit,
            ],
            env=environment,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Git blob object ID mismatch", result.stderr)

    def test_build_directory_swap_during_fetch_fails_before_victim_write(self):
        result, _, _, _, _ = self.run_build("swap", race="swap-build")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a physical directory", result.stderr)
        victim = self.root / "swap-victim"
        self.assertEqual((victim / "sentinel").read_text(), "preserve")
        self.assertEqual([path.name for path in victim.iterdir()], ["sentinel"])

    def test_sources_swap_between_locked_trees_never_writes_victim(self):
        result, _, build, _, _ = self.run_build(
            "sources-swap", race="swap-sources-after-qwen"
        )
        self.assertNotEqual(result.returncode, 0)
        victim = self.root / "sources-swap-victim"
        self.assertEqual((victim / "sentinel").read_text(), "preserve")
        self.assertEqual(
            (victim / "qwen" / "CMakeLists.txt").read_text(encoding="utf-8"),
            "victim-cmake\n",
        )
        self.assertEqual(
            os.readlink(victim / "qwen" / "ggml" / "build"),
            "victim-build-target",
        )
        held_ggml = (
            build / "held-sources-after-test-swap" / "qwen" / "ggml"
            / "ggml.cpp"
        )
        self.assertEqual(held_ggml.read_text(encoding="utf-8"), "ggml\n")
        held_qwen = build / "held-sources-after-test-swap" / "qwen"
        self.assertNotIn(
            "-march=native",
            (held_qwen / "CMakeLists.txt").read_text(encoding="utf-8"),
        )
        self.assertEqual(
            os.readlink(held_qwen / "ggml" / "build"),
            "../../../deps/ggml",
        )

    def test_critical_descendant_swap_is_caught_before_next_build_step(self):
        result, _, _, _, _ = self.run_build(
            "critical-swap", critical_swap=True
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("critical helper build directory changed", result.stderr)
        victim = self.root / "critical-swap-critical-victim"
        self.assertEqual((victim / "sentinel").read_text(), "preserve")
        self.assertEqual([path.name for path in victim.iterdir()], ["sentinel"])
        self.assertEqual(
            len(self.cmake_log.read_text(encoding="utf-8").splitlines()), 1
        )

    def test_source_content_mutation_after_configure_is_caught(self):
        result, _, _, _, _ = self.run_build(
            "source-content-mutation", mutate_source=True
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source/build manifest changed", result.stderr)
        self.assertEqual(
            len(self.cmake_log.read_text(encoding="utf-8").splitlines()), 1
        )

    def test_source_directory_replacement_after_configure_is_caught(self):
        result, _, _, _, _ = self.run_build(
            "source-directory-swap", swap_source_dir=True
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source/build manifest changed", result.stderr)
        self.assertEqual(
            len(self.cmake_log.read_text(encoding="utf-8").splitlines()), 1
        )

    def test_artifact_swap_during_probe_is_rejected(self):
        result, _, _, _, _ = self.run_build(
            "artifact-swap", artifact_swap=True
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "artifact identity or hash changed during probes", result.stderr
        )

    @unittest.skipUnless(sys.platform == "darwin", "otool is macOS-specific")
    def test_artifact_source_checkout_dependency_is_rejected(self):
        artifact = self.root / "probe-artifact"
        artifact.write_text(
            """#!/bin/sh
case "$1" in
--protocol-version) printf '1\\n' ;;
--self-test) printf '{"ok":true,"protocol":1,"engine":"fake-qwen"}\\n' ;;
*) exit 2 ;;
esac
""",
            encoding="utf-8",
        )
        artifact.chmod(0o755)
        source = self.root / "audited-source"
        source.mkdir()
        otool = self.fake_bin / "otool"
        otool.write_text(
            f"""#!/bin/sh
printf '%s:\\n' "$2"
printf '\\t{source}/libggml.dylib (compatibility version 0, current version 0)\\n'
""",
            encoding="utf-8",
        )
        otool.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = (
            str(self.fake_bin) + os.pathsep + environment["PATH"]
        )
        result = subprocess.run(
            [
                "python3", str(HERE / "validate_artifact.py"), str(artifact),
                "--engine", "fake-qwen", "--source-root", str(source),
            ],
            env=environment,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dependency points into source checkout", result.stderr)

    def test_claim_parent_swap_uses_held_parent_and_never_victim(self):
        parent = (self.root / "claim-parent").resolve()
        parent.mkdir()
        victim = self.root / "claim-victim"
        victim.mkdir()
        (victim / "sentinel").write_text("preserve", encoding="utf-8")
        environment = os.environ.copy()
        environment["TTS_BUILD_GUARD_TEST_PARENT_SWAP_VICTIM"] = str(victim)
        result = subprocess.run(
            [
                "python3", str(HERE / "build_tree_guard.py"),
                "claim", str(parent / "claimed-build"),
            ],
            env=environment,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(parent.is_symlink())
        self.assertFalse((victim / "claimed-build").exists())
        self.assertEqual((victim / "sentinel").read_text(), "preserve")
        held = self.root / "claim-parent.held-parent-after-test-swap"
        self.assertTrue((held / "claimed-build").is_dir())

    def test_two_builds_competing_for_same_path_have_one_winner(self):
        source = (self.root / "competition-source").resolve()
        build = (self.root / "competition-build").resolve()
        fetched = subprocess.run(
            [
                str(HERE / "fetch_sources.sh"), "--test-local-repositories",
                str(self.qwen_repo), self.qwen_commit,
                str(self.ggml_repo), self.ggml_commit, str(source),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(fetched.returncode, 0, fetched.stderr)
        environment = self.environment.copy()
        environment.update({
            "QWEN3_TTS_SOURCE": str(source),
            "TTS_HELPER_BUILD_DIR": str(build),
            "EXPECTED_SOURCE_LINK": str(
                build / "sources" / "qwen" / "ggml" / "build"
            ),
            "EXPECTED_EXTERNAL_BUILD": str(build / "deps" / "ggml"),
            "EXPECTED_BUILD_SOURCE": str(build / "sources" / "qwen"),
            "EXPECTED_BUILD_ROOT": str(build),
            "FAKE_CMAKE_FAIL": "0",
            "FAKE_OUTPUT_LAYOUT": "root",
            "FAKE_INJECT_NATIVE_FLAGS": "0",
        })
        command = [
            str(BUILD), "--test-local-repositories",
            str(self.qwen_repo), self.qwen_commit,
            str(self.ggml_repo), self.ggml_commit,
        ]
        processes = [
            subprocess.Popen(
                command, env=environment, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True
            )
            for _ in range(2)
        ]
        results = [process.communicate(timeout=10) for process in processes]
        codes = sorted(process.returncode for process in processes)
        self.assertEqual(codes, [0, 1], results)


if __name__ == "__main__":
    unittest.main(verbosity=2)
