#!/bin/sh
# Fetch the Godot editor binary into $GODOT_BIN, and with --templates the
# macOS and Windows export templates. Meant for CI; locally you already have
# Godot, and templates go in the same directory this writes to.
#
# Only the files the two presets need are kept from the 1.3 GB template
# bundle, which is what makes the directory small enough to cache.
set -eu

version=${GODOT_VERSION:?set GODOT_VERSION, e.g. 4.7.1}
bin=${GODOT_BIN:?set GODOT_BIN to where the editor should go}
base="https://github.com/godotengine/godot/releases/download/${version}-stable"
templates="$HOME/.local/share/godot/export_templates/${version}.stable"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ ! -x "$bin" ]; then
	curl -fsSL -o "$tmp/godot.zip" "$base/Godot_v${version}-stable_linux.x86_64.zip"
	unzip -q "$tmp/godot.zip" -d "$tmp/godot"
	mkdir -p "$(dirname -- "$bin")"
	mv "$tmp/godot/Godot_v${version}-stable_linux.x86_64" "$bin"
	chmod +x "$bin"
fi
"$bin" --version

[ "${1:-}" = "--templates" ] || exit 0

if [ -f "$templates/macos.zip" ] && [ -f "$templates/windows_release_x86_64.exe" ]; then
	echo "Export templates already present (cache hit)."
	exit 0
fi
curl -fsSL -o "$tmp/templates.tpz" "$base/Godot_v${version}-stable_export_templates.tpz"
mkdir -p "$templates"
unzip -q -j "$tmp/templates.tpz" -d "$templates" \
	"templates/version.txt" \
	"templates/macos.zip" \
	"templates/windows_release_x86_64.exe" \
	"templates/windows_release_x86_64_console.exe" \
	"templates/windows_debug_x86_64.exe" \
	"templates/windows_debug_x86_64_console.exe"
ls -l "$templates"
