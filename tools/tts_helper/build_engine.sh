#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_dir=${QWEN3_TTS_SOURCE:-/tmp/godot-pet-qwen3-tts}
build_dir=${TTS_HELPER_BUILD_DIR:-"$project_root/build/tts_helper_engine"}
jobs=${TTS_HELPER_JOBS:-4}
if [ "${TTS_HELPER_BUILD_DIR+x}" = x ]; then
	using_default_build=0
else
	using_default_build=1
fi

if [ "$#" -ne 0 ] && [ "${1:-}" != "--test-local-repositories" ]; then
	printf 'unsupported build_engine.sh arguments\n' >&2
	exit 2
fi
if [ "${1:-}" = "--test-local-repositories" ] && [ "$#" -ne 5 ]; then
	printf '%s\n' \
		'usage: build_engine.sh --test-local-repositories QWEN_REPO QWEN_SHA GGML_REPO GGML_SHA' \
		>&2
	exit 2
fi

if ! command -v cmake >/dev/null 2>&1; then
	printf 'cmake is required to build the pinned qwen and ggml sources\n' >&2
	exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
	printf 'python3 is required to validate and prepare isolated build paths\n' >&2
	exit 2
fi
if ! command -v make >/dev/null 2>&1; then
	printf 'make is required by the fixed Unix Makefiles generator\n' >&2
	exit 2
fi
if [ -L "$build_dir" ]; then
	printf 'refusing symbolic-link helper build path: %s\n' "$build_dir" >&2
	exit 1
fi

canonical=$(python3 - "$source_dir" "$build_dir" "$project_root" <<'PY'
from pathlib import Path
import sys

for value in sys.argv[1:]:
    if any(character in value for character in "\r\n\0"):
        raise SystemExit("refusing path containing CR, LF, or NUL")
source, build, project = (Path(value).resolve(strict=False) for value in sys.argv[1:])
for value in (source, build, project):
    if any(character in str(value) for character in "\r\n\0"):
        raise SystemExit("refusing canonical path containing CR, LF, or NUL")
if source == build or source in build.parents or build in source.parents:
    raise SystemExit("refusing overlapping source and helper build paths")
if source == project or project in source.parents:
    raise SystemExit("refusing audited source checkout inside project root")
print(source)
print(build)
print(project)
PY
) || exit 1
source_dir=$(printf '%s\n' "$canonical" | sed -n '1p')
build_dir=$(printf '%s\n' "$canonical" | sed -n '2p')
project_root=$(printf '%s\n' "$canonical" | sed -n '3p')

if [ "$using_default_build" -eq 1 ]; then
	python3 - "$project_root" <<'PY'
import os
import sys

root = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try:
    try:
        os.mkdir("build", 0o700, dir_fd=root)
    except FileExistsError:
        pass
    child = os.open(
        "build", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root
    )
    os.close(child)
finally:
    os.close(root)
PY
	build_dir=$project_root/build/tts_helper_engine
fi

build_identity=$(python3 "$script_dir/build_tree_guard.py" claim "$build_dir")
assert_build_identity() {
	python3 "$script_dir/build_tree_guard.py" check \
		"$build_dir" "$build_identity"
}
build_seal=
assert_build_tree() {
	python3 "$script_dir/build_tree_guard.py" check-all \
		"$build_dir" "$build_seal"
}

if [ "${1:-}" = "--test-local-repositories" ]; then
	qwen_commit=$3
	ggml_commit=$5
	"$script_dir/fetch_sources.sh" --test-local-repositories \
		"$2" "$3" "$4" "$5" "$source_dir"
else
	qwen_commit=b3ba14077cf1b3e11b86e5f84aa9184605c89b28
	ggml_commit=3af5f5760e19a96427f5f7a93b79cbdf3d4b265b
	"$script_dir/fetch_sources.sh" "$source_dir"
fi

assert_build_identity
ggml_build_dir=$build_dir/deps/ggml
build_source=$build_dir/sources/qwen
python3 "$script_dir/materialize_git_tree.py" \
	"$build_dir" "$build_identity" \
	"$source_dir" "$qwen_commit" \
	"$source_dir/ggml" "$ggml_commit"
build_seal=$(python3 "$script_dir/build_tree_guard.py" seal "$build_dir")

assert_build_tree
cmake \
	-G "Unix Makefiles" \
	-S "$build_source/ggml" \
	-B "$ggml_build_dir" \
	-DCMAKE_BUILD_TYPE=Release \
	-DGGML_BUILD_TESTS=OFF \
	-DGGML_BUILD_EXAMPLES=OFF \
	-DGGML_NATIVE=OFF
assert_build_tree
python3 "$script_dir/scan_native_flags.py" "$ggml_build_dir"
assert_build_tree
cmake --build "$ggml_build_dir" --config Release --parallel "$jobs"

assert_build_tree
cmake \
	-G "Unix Makefiles" \
	-S "$script_dir" \
	-B "$build_dir" \
	-DCMAKE_BUILD_TYPE=Release \
	-DQWEN3_TTS_SOURCE="$build_source" \
	-DGGML_NATIVE=OFF
assert_build_tree
python3 "$script_dir/scan_native_flags.py" \
	"$build_dir" --exclude sources --exclude deps
assert_build_tree
cmake --build "$build_dir" \
	--config Release \
	--target godot-pet-tts-helper \
	--parallel "$jobs"
assert_build_tree

executable=
executable_count=0
for candidate in \
	"$build_dir/godot-pet-tts-helper" \
	"$build_dir/Release/godot-pet-tts-helper"
do
	if [ -f "$candidate" ] && [ -x "$candidate" ] && [ ! -L "$candidate" ]; then
		executable=$candidate
		executable_count=$((executable_count + 1))
	fi
done
if [ "$executable_count" -ne 1 ]; then
	printf 'expected exactly one regular helper executable, found %s\n' \
		"$executable_count" >&2
	exit 1
fi
expected_engine=${TTS_HELPER_EXPECTED_ENGINE:-qwen3-tts}
if [ "${TTS_HELPER_TEST_SKIP_OTOOL:-0}" = 1 ]; then
	python3 "$script_dir/validate_artifact.py" \
		"$executable" \
		--source-root "$source_dir" \
		--engine "$expected_engine" \
		--skip-otool
else
	python3 "$script_dir/validate_artifact.py" \
		"$executable" \
		--source-root "$source_dir" \
		--engine "$expected_engine"
fi
