#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
output=${1:-"$project_root/build/tts_helper_stub"}
compiler=${CXX:-c++}

mkdir -p "$(dirname -- "$output")"
"$compiler" \
	-std=c++17 \
	-O2 \
	-Wall \
	-Wextra \
	-Wpedantic \
	"$script_dir/main.cpp" \
	-o "$output"

printf '%s\n' "$output"
