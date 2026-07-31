#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
output=${1:-"$project_root/build/tts_helper_fake"}
compiler=${CXX:-c++}
extra_flags=${TTS_HELPER_CXXFLAGS:-}

mkdir -p "$(dirname -- "$output")"
"$compiler" \
	-std=c++17 \
	-O2 \
	-Wall \
	-Wextra \
	-Wpedantic \
	$extra_flags \
	-pthread \
	-DTTS_HELPER_FAKE_QWEN=1 \
	-I"$script_dir" \
	"$script_dir/main.cpp" \
	"$script_dir/qwen_engine.cpp" \
	"$script_dir/fake_qwen3tts_c_api.cpp" \
	-o "$output"

printf '%s\n' "$output"
