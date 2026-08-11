#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(dirname -- "$script_dir")
source_file="$project_root/native/macos/system_audio_capture.swift"
output_file="$project_root/native/macos/system_audio_capture.bin"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/godot-pet-audio-helper.XXXXXX")

cleanup() {
	rm -rf "$build_dir"
}
trap cleanup EXIT HUP INT TERM

swiftc -O -parse-as-library -target arm64-apple-macosx13.0 \
	-framework ScreenCaptureKit -framework CoreMedia -framework AudioToolbox \
	"$source_file" -o "$build_dir/system_audio_capture-arm64"
swiftc -O -parse-as-library -target x86_64-apple-macosx13.0 \
	-framework ScreenCaptureKit -framework CoreMedia -framework AudioToolbox \
	"$source_file" -o "$build_dir/system_audio_capture-x86_64"
lipo -create \
	"$build_dir/system_audio_capture-arm64" \
	"$build_dir/system_audio_capture-x86_64" \
	-output "$output_file"
codesign --force --sign - --identifier net.anfusolutions.godotpet.system-audio-capture \
	"$output_file"
chmod 755 "$output_file"
echo "Built $output_file"
